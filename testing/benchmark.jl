using GPUArrays
using DataFrames, Tables, Statistics, CSV

using BenchmarkTools


BenchmarkTools.DEFAULT_PARAMETERS.samples = 10000
BenchmarkTools.DEFAULT_PARAMETERS.evals = 10

# TODO add delta between the reduction results
# with tables we can implement a custom table type for BenchmarkTools.Trial
Tables.istable(::Type{<:BenchmarkTools.Trial}) = true
Tables.columnaccess(::Type{<:BenchmarkTools.Trial}) = true
Tables.columns(m::BenchmarkTools.Trial) = m
Tables.columnnames(m::BenchmarkTools.Trial) = [:times, :gctimes, :memory, :allocs]
Tables.schema(m::BenchmarkTools.Trial) = Tables.Schema(Tables.columnnames(m), (Float64, Float64, Int, Int))
function Tables.getcolumn(m::BenchmarkTools.Trial, i::Int)
    i == 1 && return m.times
    i == 2 && return m.gctimes
    i == 3 && return fill(m.memory, length(m.times))
    return fill(m.allocs, length(m.times))
end
Tables.getcolumn(m::BenchmarkTools.Trial, nm::Symbol) = Tables.getcolumn(m, nm == :times ? 1 : nm == :gctimes ? 2 : nm == :memory ? 3 : 4)

function benchmark_CUDA(warps)
    results = []
    N = []
    
    n =128 
    while n < 5_000_000 
        data=CUDA.ones(n)
        final=CUDA.ones(1)

        dev = CUDA.device()
    
        # this will take longer as every iteration the function will be parsed
        bench = @benchmarkable CUDA.@sync( begin GPUArrays.mapreducedim!(x->x, +, $final, $data; init=Float32(0.00),shuffle=$warps) end) evals=1 samples=10000 seconds = 10000

        result = run(bench)
        display(result)
 
        # add result to results
        push!(results, result)
        push!(N, n)

        n = n * 2

        sleep(30)

    end 

    df_benchmark = mapreduce(vcat, zip(results, N)) do (x, y)
        df = DataFrame(x)
        df.N .= y
        df
    end

    #return df_benchmark
    return df_benchmark
end

function benchmark_KA(warps,atomics)
    groupsize = [256 ,512, 1024]
    items_per_workitem = [16, 32, 64]
    groups_multiplier = [1]

    for g in groupsize
        @show g
        for i in items_per_workitem
            @show i
            for m in groups_multiplier
                @show m
                n = 128

                while n < 5_000_000 
                    data = CUDA.ones(n)
                    final = CUDA.ones(1)

                    dev = CUDA.device()
        
                    major = CUDA.capability(dev).major
                    max_groupsize = if major >= 3 1024 else 512 end
                    gridsize = CUDA.attribute(dev, CUDA.DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT)
                    max_concurrency = max_groupsize * gridsize
                    # supports_atomics = if warps == nothing major >= 2 else atomics end
                    # supports_warp_reduce = if warps == nothing major >= 5 else warps end
                    supports_atomics = atomics
                    supports_warp_reduce = warps

                    max_ndrange = g * gridsize * m

                    conf = Config(g,32, max_ndrange, i, supports_atomics, supports_warp_reduce)
                    #@show conf

                    results = []
                    N = []
                    groupsizes = []
                    items_per_workitems = []
                    groups_multipliers = []


                    # this will take longer as every iteration the function will be parsed
            
                    for idk in 1:10
                        bench = @benchmarkable CUDA.@sync( begin mapreducedim!(x->x, +, $final, $data; init=Float32(0.00),conf=$conf) end) evals=1 samples=500 seconds = 10000

                        result = run(bench)

                        display(result)
            
                        # add result to results
                        push!(results, result)
                        push!(N, n)
                        push!(groupsizes, g)
                        push!(items_per_workitems, i)
                        push!(groups_multipliers, m)
                    end
            
                    n = n * 2
            
                    data = nothing
                    partial = nothing
                    
                    CUDA.reclaim()

                    df_benchmark = mapreduce(vcat, zip(results, N, groupsizes,items_per_workitems, groups_multipliers)) do (x,y, groupsizes,items_per_workitems, groups_multipliers )
                        df = DataFrame(x)
                        df.N .= y
                        df.groupsize .= groupsizes
                        df.items_per_workitem .= items_per_workitems
                        df.groups_multiplier .= groups_multipliers
                        df
                    end
    
                    df_benchmark.atomics .= atomics
                    df_benchmark.warps .= warps
                    df_benchmark.package .= "KernelAbstractions.jl"
        
                    CSV.write("KA.csv", df_benchmark, append=true)                  
                end         
            end
        end
    end 
end

function benchmark_NVIDIA()
    benchmark_KA(false, false)
end

benchmark_NVIDIA()