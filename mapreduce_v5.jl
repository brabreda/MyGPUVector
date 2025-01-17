using KernelAbstractions
using Atomix

@enum GroupReduceAlgorithm  begin 
    THREADS
    WARP_WARP
    SEQUENTIAL_WARP
end

@inline _map_getindex(args::Tuple, I) = ((args[1][I]), _map_getindex(Base.tail(args), I)...)
@inline _map_getindex(args::Tuple{Any}, I) = ((args[1][I]),)
@inline _map_getindex(args::Tuple{}, I) = ()

# we will still need some global temperary memory reduce between blocks
# NOTE: when every thread only needs to handle 1  the reduction wil just 
# result in heirachical block reductions

macro groupreduce(op, val, neutral, conf) 
    quote
        # use heuristic to determine the best algorithm only use groupreduce with only warps
        # if we groupsize is warpsize * warpsize. This way we don't have to use neutral elements.
        # This also seams to be faster for CUDA
        # if else will be optimized away by the compiler because the values are compile time constants
        algo = if $(esc(conf)).use_warps
            $(esc(conf)).warpsize * $(esc(conf)).warpsize == $(esc(conf)).groupsize ? WARP_WARP : SEQUENTIAL_WARP
        else 
            THREADS
        end
        # Using Val so that  algo is in the type domain and we can use it to #dispatch the right algorithm
        $__groupreduce($(esc(:__ctx__)),$(esc(op)), $(esc(val)), $(esc(neutral)), typeof($(esc(val))), Val(algo))
    end
end

@inline function __groupreduce(__ctx__, op, val, neutral, ::Type{T}, ::Val{WARP_WARP::GroupReduceAlgorithm}) where {T}
    threadIdx_local = KernelAbstractions.@index(Local)
    groupsize = KernelAbstractions.@groupsize()[1]
    subgroupsize = KernelAbstractions.@subgroupsize()

    shared = KernelAbstractions.@localmem(T, subgroupsize)

    subgroupIdx, subgroupLane = fldmod1(threadIdx_local, subgroupsize)

    # each warp performs partial reduction
    val = KernelAbstractions.@subgroupreduce(op, val)

    # write reduced value to shared memory
    if subgroupLane == 1
        @inbounds shared[warpIdx] = val
    end

    # wait for all partial reductions
    KernelAbstractions.@synchronize()

    # read from shared memory only if that warp existed
    val = if threadIdx_local <= fld1(groupsize, subgroupsize)
            @inbounds shared[warpLane]
    else
        neutral
    end

    # final reduce within first warp
    if subgroupIdx == 1
        val =  KernelAbstractions.@subgroupreduce(op, val)
    end

    return val
end

@inline function __groupreduce(__ctx__, op, val, neutral, ::Type{T}, ::Val{SEQUENTIAL_WARP::GroupReduceAlgorithm}) where {T}
    threadIdx_local = KernelAbstractions.@index(Local)
    groupsize = KernelAbstractions.@groupsize()[1]
    subgroupsize = KernelAbstractions.@subgroupsize()
    subgroupIdx, subgroupLane = fldmod1(threadIdx_local, subgroupsize)
    items_per_workitem = cld(groupsize, subgroupsize)

    shared = KernelAbstractions.@localmem(T, groupsize)

    @inbounds shared[threadIdx_local] = val 
    KernelAbstractions.@synchronize()

    if subgroupIdx == 1
        startIdx = ((threadIdx_local- 1) * items_per_workitem) + 1

        val = @inbounds shared[startIdx]
        index = startIdx + 1
        while index <= startIdx + items_per_workitem - 1
            val = op(val, shared[index])
            index += 1
        end

        val = KernelAbstractions.@subgroupreduce(op, val)
    end

    return val
end

@inline function __groupreduce(__ctx__, op, val, neutral, ::Type{T}, ::Val{THREADS::GroupReduceAlgorithm}) where {T}
    threadIdx_local = KernelAbstractions.@index(Local)
    groupsize = KernelAbstractions.@groupsize()[1]
    
    shared = KernelAbstractions.@localmem(T, groupsize)

    @inbounds shared[threadIdx_local] = val

    # perform the reduction
    d = 1
    while d < groupsize
        KernelAbstractions.@synchronize()
        index = 2 * d * (threadIdx_local-1) + 1
        @inbounds if index <= groupsize
            other_val = if index + d <= groupsize
                shared[index+d]
            else
                neutral
            end
            shared[index] = op(shared[index], other_val)
        end
        d *= 2
    end

    # load the final value on the first thread
    if threadIdx_local == 1
        val = @inbounds shared[threadIdx_local]
    end
    
    return val 
end



@kernel function reduce_kernel(f, op, neutral, R, A , conf)
    # values for the kernel
        threadIdx_local = @index(Local)
        threadIdx_global = @index(Global)
        groupIdx = @index(Group)
        gridsize = @ndrange()[1]

        # load neutral value
        neutral = if neutral === nothing
            R[1]
        else
            neutral
        end
        
        val = op(neutral, neutral)

        # every thread reduces a few values parrallel
        index = threadIdx_global 
        while index <= length(A)
            val = op(val,f(A[index]))
            index += gridsize
        end

        # reduce every block to a single value
        val = @groupreduce(op, val, neutral, conf)

        # use helper function to deal with atomic/non atomic reductions
        if threadIdx_local == 1
            if conf.use_atomics
                ref = Atomix.IndexableRef(R, (1,));
                Atomix.modify!(ref, op, val)
            else
                @inbounds R[groupIdx] = val
            end
        end
end


# generic mapreduce
function mapreducedim!(f::F, op::OP, R, A::Union{AbstractArray,Broadcast.Broadcasted}; init=nothing, conf=nothing) where {F, OP}

    Base.check_reducedims(R, A)
    length(A) == 0 && return R # isempty(::Broadcasted) iterates

    # add singleton dimensions to the output container, if needed
    if ndims(R) < ndims(A)
        dims = Base.fill_to_length(size(R), 1, Val(ndims(A)))
        R = reshape(R, dims)
    end
    
    backend = KernelAbstractions.get_backend(A) 

    conf = if conf == nothing KernelAbstractions.get_reduce_config(backend, op, eltype(A)) else conf end
    if length(R) == 1
        if length(A) <= conf.items_per_workitem * conf.groupsize

            reduce_kernel(backend, conf.groupsize)(f, op, init, R, A, conf, ndrange=conf.groupsize)
            return R
        else
            # How many workitems do we want?
            gridsize = cld(length(A), conf.items_per_workitem)
            # how many workitems can we have?
            gridsize = min(gridsize, conf.max_ndrange)

            groups = cld(gridsize, conf.groupsize)
            partial = conf.use_atomics==true ? R : similar(R, (size(R)...,groups))

            reduce_kernel(backend, conf.groupsize)(f, op, init, partial, A, conf, ndrange=gridsize)
            
            if !conf.use_atomics
                mapreducedim!(x->x, op, R, partial; init=init,conf=conf)
            end   
        end
    else
        # ...
    end

    return R
end

