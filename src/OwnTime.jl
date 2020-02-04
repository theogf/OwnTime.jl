module OwnTime

export owntime, totaltime, filecontains
export framecounts, frametotal, frames

using Printf
using Profile

const StackFrame = StackTraces.StackFrame

function countmap(iter)
    result = Dict{eltype(iter), Int64}()
    for i in iter
        if haskey(result, i)
            result[i] += 1
        else
            result[i] = 1
        end
    end
    result
end

mutable struct OwnTimeState
    last_fetched_data :: Union{Nothing, Vector{UInt64}}
    last_stacktraces :: Union{Nothing, Vector{Vector{StackFrame}}}
end

const state = OwnTimeState(nothing, nothing)

new_data() = fetch()[3]

"""
    clear()

OwnTime has an internal cache for performance. Clear that cache.

See also: [`Profile.clear`](@ref)
"""
function clear()
    state.last_fetched_data = nothing
    state.last_stacktraces = nothing
end

"""
    fetch()

Return a 3-tuple of the form `(instruction_pointers, is_profile_buffer_full, is_there_new_data)`.

This function is primarily for internal use.

See also: [`Profile.fetch`](@ref)
"""
function fetch()
    maxlen = Profile.maxlen_data()
    len = Profile.len_data()
    data = Vector{UInt}(undef, len)
    GC.@preserve data unsafe_copyto!(pointer(data), Profile.get_data_pointer(), len)
    new_data = data != state.last_fetched_data
    state.last_fetched_data = data
    return data, len == maxlen, new_data
end

"""
    backtraces(;warn_on_full_buffer=true)

Return an array of backtraces. A backtrace is an array of instruction pointers.

This function is primarily for internal use, try calling `OwnTime.stacktraces()` instead.

This function may give a warning if Julia's profiling buffer is full.
This warning can be disabled with the relative function parameter.

See also: [`backtrace`](@ref)
"""
function backtraces(;warn_on_full_buffer=true)
    profile_pointers, full_buffer, _new_profile_pointers = fetch()
    if warn_on_full_buffer && full_buffer
        @warn """The profile data buffer is full; profiling probably terminated
                 before your program finished. To profile for longer runs, call
                 `Profile.init()` with a larger buffer and/or larger delay."""
    end
    bts = Vector{UInt64}[]
    i = 1
    for j in 1:length(profile_pointers)
        # 0 is a sentinel value that indicates the start of a new backtrace.
        # See the source code for `tree!` in Julia's Profile package.
        if profile_pointers[j] == 0
            push!(bts, profile_pointers[i:j-1])
            i = j+1
        end
    end
    filter(!isempty, bts)
end

"""
    stacktraces([backtraces]; warn_on_full_buffer=true)

Return an array of `StackTrace`s. A `StackTrace` is an array of `StackFrame`s.

This function may take several minutes if you have a large profile buffer.

See also: [`stacktrace`](@ref), [`StackTraces.StackTrace`](@ref), [`StackTraces.StackFrame`](@ref)
"""
function stacktraces(;warn_on_full_buffer=true)
    if !new_data() && !isnothing(state.last_stacktraces)
        state.last_stacktraces
    else
        bts = backtraces(warn_on_full_buffer=warn_on_full_buffer)
        stacktraces(bts)
    end
end

function stacktraces(backtraces)
    # Lookups are very slow, so we will lookup each unique pointer only once.
    lookups = Dict(p => StackTraces.lookup(p) for p in unique(reduce(vcat, backtraces, init=[])))
    sts = map(backtraces) do backtrace
        filter(reduce(vcat, map(p -> lookups[p], backtrace))) do stackframe
            stackframe.from_c == false
        end
    end
    state.last_stacktraces = sts
    sts
end

struct FrameCounts
    counts :: Vector{Pair{StackFrame,Int64}}
    total :: Int64
end

framecounts(fcs::FrameCounts) = fcs.counts

frametotal(fcs::FrameCounts) = fcs.total

frames(fcs::FrameCounts) = map(fcs -> fcs.first, fcs.counts)

Base.getindex(fcs::FrameCounts, i) = framecounts(fcs)[i]
Base.iterate(fcs::FrameCounts) = iterate(framecounts(fcs))
Base.iterate(fcs::FrameCounts, state) = iterate(framecounts(fcs), state)
Base.length(fcs::FrameCounts) = length(framecounts(fcs))

function Base.show(io::IO, fcs::FrameCounts)
    for (i, (stackframe, count)) in enumerate(fcs)
        percent_of_time = round(count / frametotal(fcs) * 100)
        if percent_of_time >= 1
            @printf(io, "%4s %3d%% => %s\n", @sprintf("[%d]", i), percent_of_time, stackframe)
        end
    end
end

"""
    owntime([stacktraces]; stackframe_filter, warn_on_full_buffer=true)

Count the time spent on each `StackFrame` *excluding* its sub-calls.

If supplied, `stackframe_filter` should be a function that accepts a single `StackFrame`
and returns `true` if it should be included in the counts.

More advance filtering my by done by preprocessing the `StackTrace`s from
`OwnTime.stacktraces()` and then passing those `StackTrace`s to this function.

See also: [`OwnTime.stacktraces`](@ref) [`StackTraces.StackFrame`](@ref)
"""
function owntime(;stackframe_filter=stackframe -> true, warn_on_full_buffer=true)
    sts = stacktraces(warn_on_full_buffer=warn_on_full_buffer)
    owntime(sts; stackframe_filter=stackframe_filter)
end

function owntime(stacktraces; stackframe_filter=stackframe -> true)
    filtered_stacktraces = map(stacktraces) do stackframes
        filter(stackframe_filter, stackframes)
    end
    nonempty_stacktraces = filter(!isempty, filtered_stacktraces)
    framecounts = countmap(reduce(vcat, first.(nonempty_stacktraces), init=StackFrame[]))
    FrameCounts(sort(collect(framecounts), by=pair -> pair.second, rev=true), length(stacktraces))
end

"""
    totaltime([stacktraces]; stackframe_filter, warn_on_full_buffer=true)

Count the time spent on each `StackFrame` *including* its sub-calls.

If supplied, `stackframe_filter` should be a function that accepts a single `StackFrame`
and returns `true` if it should be included in the counts.

More advance filtering my by done by preprocessing the `StackTrace`s from
`OwnTime.stacktraces()` and then passing those `StackTrace`s to this function.

See also: [`OwnTime.stacktraces`](@ref) [`StackTraces.StackFrame`](@ref)
"""
function totaltime(;stackframe_filter=stackframe -> true, warn_on_full_buffer=true)
    sts = stacktraces(warn_on_full_buffer=warn_on_full_buffer)
    totaltime(sts; stackframe_filter=stackframe_filter)
end

function totaltime(stacktraces; stackframe_filter=stackframe -> true)
    filtered_stacktraces = map(stacktraces) do stackframes
        filter(stackframe_filter, stackframes)
    end
    framecounts = countmap(reduce(vcat, collect.(unique.(filtered_stacktraces)), init=StackFrame[]))
    FrameCounts(sort(collect(framecounts), by=pair -> pair.second, rev=true), length(stacktraces))
end

"""
    filecontains(needle)

A `StackFrame` filter that returns `true` if the given `StackFrame` has `needle` in its file path.

# Example
```julia-repl
julia> stackframe = stacktrace()[1]
top-level scope at REPL[6]:1

julia> stackframe.file
Symbol("REPL[6]")

julia> filecontains("REPL")(stackframe)
true
```

See also: [`StackTraces.StackFrame`](@ref)
"""
function filecontains(needle)
    function (stackframe)
        haystack = string(stackframe.file)
        occursin(needle, haystack)
    end
end

end # module
