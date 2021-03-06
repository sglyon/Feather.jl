__precompile__(true)
module Feather

using FlatBuffers, Missings, WeakRefStrings, CategoricalArrays, DataStreams, DataFrames

if Base.VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
end

if Base.VERSION >= v"0.7.0-DEV.2009"
    using Mmap
end

export Data

# because there's currently not a better place for these to live
# import Base.==
# ==(x::WeakRefString{T}, y::CategoricalArrays.CategoricalValue) where {T} = string(x) == string(y)
# ==(y::CategoricalArrays.CategoricalValue, x::WeakRefString{T}) where {T} = string(x) == string(y)

# sync with feather
const VERSION = 2

# Arrow type definitions
include("Arrow.jl")

# flatbuffer defintions
include("metadata.jl")

# wesm/feather/cpp/src/common.h
const FEATHER_MAGIC_BYTES = Vector{UInt8}("FEA1")

bytes_for_bits(size) = div(((size + 7) & ~7), 8)
const BITMASK = UInt8[1, 2, 4, 8, 16, 32, 64, 128]
getbit(byte::UInt8, i) = (byte & BITMASK[i]) == 0
const ALIGNMENT = 8
paddedlength(x) = div((x + ALIGNMENT - 1), ALIGNMENT) * ALIGNMENT
getoutputlength(version, x) = version < VERSION ? x : paddedlength(x)

function writepadded(io, x)
    bw = Base.write(io, x)
    diff = paddedlength(bw) - bw
    Base.write(io, zeros(UInt8, diff))
    return bw + diff
end
function writepadded(io, x::Vector{String})
    bw = 0
    for str in x
        bw += Base.write(io, str)
    end
    diff = paddedlength(bw) - bw
    Base.write(io, zeros(UInt8, diff))
    return bw + diff
end

juliastoragetype(meta::Void, values_type) = Type_2julia[values_type]
function juliastoragetype(meta::Metadata.CategoryMetadata, values_type)
    R = Type_2julia[values_type]
    return CategoricalString{R}
end
juliastoragetype(meta::Metadata.TimestampMetadata, values_type) = Arrow.Timestamp{TimeUnit2julia[meta.unit],meta.timezone == "" ? :UTC : Symbol(meta.timezone)}
juliastoragetype(meta::Metadata.DateMetadata, values_type) = Arrow.Date
juliastoragetype(meta::Metadata.TimeMetadata, values_type) = Arrow.Time{TimeUnit2julia[meta.unit]}

juliatype(::Type{<:Arrow.Timestamp}) = Dates.DateTime
juliatype(::Type{<:Arrow.Date}) = Dates.Date
juliatype(::Type{T}) where {T} = T
juliatype(::Type{Arrow.Bool}) = Bool

addlevels!(::Type{T}, levels, orders, i, meta, values_type, data, version) where {T} = return
function addlevels!(::Type{T}, catlevels, orders, i, meta, values_type, data, version) where {T <: CategoricalString}
    ptr = convert(Ptr{Int32}, pointer(data) + meta.levels.offset)
    offsets = [unsafe_load(ptr, i) for i = 1:meta.levels.length + 1]
    ptr += getoutputlength(version, sizeof(offsets))
    ptr2 = convert(Ptr{UInt8}, ptr)
    catlevels[i] = map(x->unsafe_string(ptr2 + offsets[x], offsets[x+1] - offsets[x]), 1:meta.levels.length)
    orders[i] = meta.ordered
    return
end

schematype(::Type{T}, nullcount, nullable, wrs) where {T} = ifelse(nullcount == 0 && !nullable, T, Union{T, Missing})
schematype(::Type{<:AbstractString}, nullcount, nullable, wrs) = (s = ifelse(wrs, WeakRefString{UInt8}, String); return ifelse(nullcount == 0 && !nullable, s, Union{s, Missing}))
schematype(::Type{CategoricalString{R}}, nullcount, nullable, wrs) where {R} = ifelse(nullcount == 0 && !nullable, CategoricalString{R}, Union{CategoricalString{R}, Missing})

# DataStreams interface types
mutable struct Source{S, T} <: Data.Source
    path::String
    schema::Data.Schema
    ctable::Metadata.CTable
    data::Vector{UInt8}
    # ::S # separate from the types in schema, since we need to convert between feather storage types & julia types
    levels::Dict{Int,Vector{String}}
    orders::Dict{Int,Bool}
    columns::T # holds references to pre-fetched columns for Data.getfield
end

if Base.VERSION < v"0.7-DEV"
    iswindows = is_windows
else
    iswindows = Sys.iswindows
end

# reading feather files
if iswindows()
    const should_use_mmap = false
else
    const should_use_mmap = true
end

function Source(file::AbstractString; nullable::Bool=false, weakrefstrings::Bool=true, use_mmap::Bool=should_use_mmap)
    # validity checks
    isfile(file) || throw(ArgumentError("'$file' is not a valid file"))
    m = use_mmap ? Mmap.mmap(file) : Base.read(file)
    length(m) < 12 && throw(ArgumentError("'$file' is not in the feather format: total length of file = $(length(m))"))
    (m[1:4] == FEATHER_MAGIC_BYTES && m[end-3:end] == FEATHER_MAGIC_BYTES) ||
        throw(ArgumentError("'$file' is not in the feather format: header = $(m[1:4]), footer = $(m[end-3:end])"))
    # read file metadata using FlatBuffers
    metalength = Base.read(IOBuffer(m[length(m)-7:length(m)-4]), Int32)
    metapos = length(m) - (metalength + 7)
    rootpos = Base.read(IOBuffer(m[metapos:metapos+4]), Int32)
    ctable = FlatBuffers.read(Metadata.CTable, m, metapos + rootpos - 1)
    ctable.version < VERSION && warn("This Feather file is old and will not be readable beyond the 0.3.0 release")
    header = String[]
    types = Type[]
    juliatypes = Type[]
    columns = ctable.columns
    levels = Dict{Int,Vector{String}}()
    orders = Dict{Int,Bool}()
    for (i, col) in enumerate(columns)
        push!(header, col.name)
        push!(types, juliastoragetype(col.metadata, col.values.type_))
        jl = juliatype(types[end])
        addlevels!(jl, levels, orders, i, col.metadata, col.values.type_, m, ctable.version)
        push!(juliatypes, schematype(jl, col.values.null_count, nullable, weakrefstrings))
    end
    sch = Data.Schema(juliatypes, header, ctable.num_rows)
    columns = DataFrame(sch, Data.Column, false)
    sch.rows = ctable.num_rows
    # construct Data.Schema and Feather.Source
    return Source{Tuple{types...}, typeof(columns)}(file, sch, ctable, m, levels, orders, columns)
end

# DataStreams interface
# allocate(::Type{T}, rows, ref) where {T} = Vector{T}(rows)
# allocate(::Type{T}, rows, ref) where {T <: Union{WeakRefString,Missing}} = WeakRefStringArray(ref, T, rows)
Data.allocate(::Type{CategoricalString{R}}, rows, ref) where {R} = CategoricalArray{String, 1, R}(rows)
Data.allocate(::Type{Union{CategoricalString{R}, Missing}}, rows, ref) where {R} = CategoricalArray{Union{String, Missing}, 1, R}(rows)

Data.schema(source::Feather.Source) = source.schema
Data.reference(source::Feather.Source) = source.data
Data.isdone(io::Feather.Source, row, col, rows, cols) =  col > cols || row > rows
function Data.isdone(io::Source, row, col)
    rows, cols = size(Data.schema(io))
    return isdone(io, row, col, rows, cols)
end
Data.streamtype(::Type{<:Feather.Source}, ::Type{Data.Column}) = true
Data.streamtype(::Type{<:Feather.Source}, ::Type{Data.Field}) = true

@inline function Data.streamfrom(source::Source, ::Type{Data.Field}, ::Type{T}, row, col) where {T}
    isempty(source.columns, col) && append!(source.columns[col], Data.streamfrom(source, Data.Column, T, row, col))
    return source.columns[col][row]
end

checknonull(source, col) = source.ctable.columns[col].values.null_count > 0 && throw(NullException)
getbools(s::Source, col) = s.ctable.columns[col].values.null_count == 0 ? zeros(Bool, s.ctable.num_rows) : Bool[getbit(s.data[s.ctable.columns[col].values.offset + bytes_for_bits(x)], mod1(x, 8)) for x = 1:s.ctable.num_rows]

@inline function unwrap(s::Source, ::Type{T}, col, rows, off=0) where {T}
    bitmask_bytes = s.ctable.columns[col].values.null_count > 0 ? Feather.getoutputlength(s.ctable.version, Feather.bytes_for_bits(s.ctable.num_rows)) : 0
    ptr = convert(Ptr{T}, pointer(s.data) + s.ctable.columns[col].values.offset + bitmask_bytes + off)
    return [unsafe_load(ptr, i) for i = 1:rows]
end

transform!(::Type{T}, A, len) where {T} = A
transform!(::Type{Dates.Date}, A, len) = map(x->Arrow.unix2date(x), A)
transform!(::Type{Dates.DateTime}, A::Vector{Arrow.Timestamp{P,Z}}, len) where {P, Z} = map(x->Arrow.unix2datetime(P, x), A)
transform!(::Type{CategoricalString{R}}, A, len) where {R} = map(x->x + R(1), A)
function transform!(::Type{Bool}, A, len)
    B = falses(len)
    Base.copy_chunks!(B.chunks, 1, map(x->x.value, A), 1, length(A) * 64)
    return convert(Vector{Bool}, B)
end

@inline function Data.streamfrom(source::Source{S}, ::Type{Data.Column}, ::Type{T}, row, col) where {S, T}
    checknonull(source, col)
    A = unwrap(source, S.parameters[col], col, source.ctable.num_rows)
    return transform!(T, A, source.ctable.num_rows)
end
@inline function Data.streamfrom(source::Source{S}, ::Type{Data.Column}, ::Type{Union{T, Missing}}, row, col) where {S, T}
    A = transform!(T, unwrap(source, S.parameters[col], col, source.ctable.num_rows), source.ctable.num_rows)
    bools = getbools(source, col)
    V = Vector{Union{T, Missing}}(A)
    foreach(x->bools[x] && (V[x] = missing), 1:length(A))
    return V
end
@inline function Data.streamfrom(source::Source{S}, ::Type{Data.Column}, ::Type{Bool}, row, col) where {S}
    checknonull(source, col)
    A = unwrap(source, S.parameters[col], col, max(1,div(bytes_for_bits(source.ctable.num_rows),8)))
    return transform!(Bool, A, source.ctable.num_rows)::Vector{Bool}
end
@inline function Data.streamfrom(source::Source, ::Type{Data.Column}, ::Type{T}, row, col) where {T <: AbstractString}
    checknonull(source, col)
    offsets = unwrap(source, Int32, col, source.ctable.num_rows + 1)
    values = unwrap(source, UInt8, col, offsets[end], getoutputlength(source.ctable.version, sizeof(offsets)))
    return T[unsafe_string(pointer(values, offsets[i]+1), Int(offsets[i+1] - offsets[i])) for i = 1:source.ctable.num_rows]
end
@inline function Data.streamfrom(source::Source, ::Type{Data.Column}, ::Type{Union{T, Missing}}, row, col) where {T <: AbstractString}
    bools = getbools(source, col)
    offsets = unwrap(source, Int32, col, source.ctable.num_rows + 1)
    values = unwrap(source, UInt8, col, offsets[end], getoutputlength(source.ctable.version, sizeof(offsets)))
    A = T[unsafe_string(pointer(values, offsets[i]+1), Int(offsets[i+1] - offsets[i])) for i = 1:source.ctable.num_rows]
    V = Vector{Union{T, Missing}}(A)
    foreach(x->bools[x] && (V[x] = missing), 1:length(A))
    return V
end
@inline function Data.streamfrom(source::Source, ::Type{Data.Column}, ::Type{WeakRefString{UInt8}}, row, col)
    checknonull(source, col)
    offsets = unwrap(source, Int32, col, source.ctable.num_rows + 1)
    offset = source.ctable.columns[col].values.offset +
             (source.ctable.columns[col].values.null_count > 0 ? Feather.getoutputlength(source.ctable.version, Feather.bytes_for_bits(source.ctable.num_rows)) : 0) +
             getoutputlength(source.ctable.version, sizeof(offsets))
    values = unwrap(source, UInt8, col, offsets[end], getoutputlength(source.ctable.version, sizeof(offsets)))
    A = [WeakRefString(pointer(source.data, offset + offsets[i]+1), Int(offsets[i+1] - offsets[i])) for i = 1:source.ctable.num_rows]
    return WeakRefStringArray(source.data, A)
end
@inline function Data.streamfrom(source::Source, ::Type{Data.Column}, ::Type{Union{WeakRefString{UInt8}, Missing}}, row, col)
    bools = getbools(source, col)
    offsets = unwrap(source, Int32, col, source.ctable.num_rows + 1)
    offset = source.ctable.columns[col].values.offset +
             (source.ctable.columns[col].values.null_count > 0 ? Feather.getoutputlength(source.ctable.version, Feather.bytes_for_bits(source.ctable.num_rows)) : 0) +
             getoutputlength(source.ctable.version, sizeof(offsets))
    values = unwrap(source, UInt8, col, offsets[end], getoutputlength(source.ctable.version, sizeof(offsets)))
    A = Union{WeakRefString{UInt8}, Missing}[WeakRefString(pointer(source.data, offset + offsets[i]+1), Int(offsets[i+1] - offsets[i])) for i = 1:source.ctable.num_rows]
    foreach(x->bools[x] && (A[x] = missing), 1:length(A))
    return WeakRefStringArray(source.data, A)
end
@inline function Data.streamfrom(source::Source, ::Type{Data.Column}, ::Type{CategoricalString{R}}, row, col) where {R}
    checknonull(source, col)
    refs = transform!(CategoricalString{R}, unwrap(source, R, col, source.ctable.num_rows), source.ctable.num_rows)
    pool = CategoricalPool{String, R}(source.levels[col], source.orders[col])
    return CategoricalArray{String,1}(refs, pool)
end
@inline function Data.streamfrom(source::Source, ::Type{Data.Column}, ::Type{Union{CategoricalString{R}, Missing}}, row, col) where {R}
    refs = transform!(CategoricalString{R}, unwrap(source, R, col, source.ctable.num_rows), source.ctable.num_rows)
    bools = getbools(source, col)
    refs = R[ifelse(bools[i], R(0), refs[i]) for i = 1:source.ctable.num_rows]
    pool = CategoricalPool{String, R}(source.levels[col], source.orders[col])
    return CategoricalArray{Union{String, Missing},1}(refs, pool)
end

"""
`Feather.read{T <: Data.Sink}(file, sink_type::Type{T}, sink_args...; weakrefstrings::Bool=true)` => `T`

`Feather.read(file, sink::Data.Sink; weakrefstrings::Bool=true)` => `Data.Sink`

`Feather.read` takes a feather-formatted binary `file` argument and "streams" the data to the
provided `sink` argument, a `DataFrame` by default. A fully constructed `sink` can be provided as the 2nd argument (the 2nd method above),
or a Sink can be constructed "on the fly" by providing the type of Sink and any necessary positional arguments
(the 1st method above).

Keyword arguments:

  * `nullable::Bool=false`: will return columns as `NullableVector{T}` types by default, regarldess of # of missing values. When set to `false`, columns without missing values will be returned as regular `Vector{T}`
  * `weakrefstrings::Bool=true`: indicates whether string-type columns should be returned as `WeakRefString` (for efficiency) or regular `String` types
  * `use_mmap::Bool=true`: indicates whether to use system `mmap` capabilities when reading the feather file; on some systems or environments, mmap may not be available or reliable (virtualbox env using shared directories can be problematic)
  * `append::Bool=false`: indicates whether the feather file should be appended to the provided `sink` argument; note that column types between the feather file and existing sink must match to allow appending
  * `transforms`: a `Dict{Int,Function}` or `Dict{String,Function}` that provides transform functions to be applied to feather fields or columns as they are parsed from the feather file; note that feather files can be parsed field-by-field or entire columns at a time, so transform functions need to operate on scalars or vectors appropriately, depending on the `sink` argument's preferred streaming type; by default, a `Feather.Source` will stream entire columns at a time, so a transform function would take a single `NullableVector{T}` argument and return an equal-length `NullableVector`

Examples:

```julia
# default read method, returns a DataFrame
df = Feather.read("cool_feather_file.feather")

# read a feather file directly into a SQLite database table
db = SQLite.DB()
Feather.read("cool_feather_file.feather", SQLite.Sink, db, "cool_feather_table")
```
"""
function read end

function read(file::AbstractString, sink=DataFrame, args...; nullable::Bool=false, weakrefstrings::Bool=true, use_mmap::Bool=true, append::Bool=false, transforms::Dict=Dict{Int,Function}())
    sink = Data.stream!(Source(file; nullable=nullable, weakrefstrings=weakrefstrings, use_mmap=use_mmap), sink, args...; append=append, transforms=transforms)
    return Data.close!(sink)
end

function read(file::AbstractString, sink::T; nullable::Bool=false, weakrefstrings::Bool=true, use_mmap::Bool=true, append::Bool=false, transforms::Dict=Dict{Int,Function}()) where {T}
    sink = Data.stream!(Source(file; nullable=nullable, weakrefstrings=weakrefstrings, use_mmap=use_mmap), sink; append=append, transforms=transforms)
    return Data.close!(sink)
end

read(source::Feather.Source, sink=DataFrame, args...; append::Bool=false, transforms::Dict=Dict{Int,Function}()) = (sink = Data.stream!(source, sink, args...; append=append, transforms=transforms); return Data.close!(sink))
read(source::Feather.Source, sink::T; append::Bool=false, transforms::Dict=Dict{Int,Function}()) where {T} = (sink = Data.stream!(source, sink; append=append, transforms=transforms); return Data.close!(sink))

# writing feather files
feathertype(::Type{T}) where {T} = Feather.julia2Type_[T]
feathertype(::Type{Union{T, Missing}}) where {T} = feathertype(T)
feathertype(::Type{CategoricalString{R}}) where {R} = julia2Type_[R]
feathertype(::Type{<:Arrow.Time}) = Metadata.INT64
feathertype(::Type{Dates.Date}) = Metadata.INT32
feathertype(::Type{Dates.DateTime}) = Metadata.INT64
feathertype(::Type{<:AbstractString}) = Metadata.UTF8

getmetadata(io, T, A) = nothing
getmetadata(io, ::Type{Union{T, Missing}}, A) where {T} = getmetadata(io, T, A)
getmetadata(io, ::Type{Dates.Date}, A) = Metadata.DateMetadata()
getmetadata(io, ::Type{Arrow.Time{T}}, A) where {T} = Metadata.TimeMetadata(julia2TimeUnit[T])
getmetadata(io, ::Type{Dates.DateTime}, A) = Metadata.TimestampMetadata(julia2TimeUnit[Arrow.Millisecond], "")
function getmetadata(io, ::Type{CategoricalString{R}}, A) where {R}
    lvls = CategoricalArrays.levels(A)
    len = length(lvls)
    offsets = zeros(Int32, len+1)
    offsets[1] = off = 0
    for (i,v) in enumerate(lvls)
        off += length(v)
        offsets[i + 1] = off
    end
    offset = position(io)
    total_bytes = writepadded(io, view(reinterpret(UInt8, offsets), 1:(sizeof(Int32) * (len + 1))))
    total_bytes += writepadded(io, lvls)
    return Metadata.CategoryMetadata(Metadata.PrimitiveArray(Metadata.UTF8, Metadata.PLAIN, offset, len, 0, total_bytes), isordered(A))
end

values(A::Vector) = A
values(A::CategoricalArray{T,1,R}) where {T, R} = map(x-> x - R(1), A.refs)

nullcount(A) = 0
nullcount(A::Vector{Union{T, Missing}}) where {T} = sum(ismissing(x) for x in A)
nullcount(A::CategoricalArray) = sum(A.refs .== 0)

# Bool
function writecolumn(io, ::Type{Bool}, A)
    return writepadded(io, view(reinterpret(UInt8, convert(BitVector, A).chunks), 1:bytes_for_bits(length(A))))
end
# Category
function writecolumn(io, ::Type{CategoricalString{R}}, A) where {R}
    return writepadded(io, view(reinterpret(UInt8, values(A)), 1:(length(A) * sizeof(R))))
end
function writecolumn(io, ::Type{Union{CategoricalString{R}, Missing}}, A) where {R}
    return writepadded(io, view(reinterpret(UInt8, values(A)), 1:(length(A) * sizeof(R))))
end
# Date
function writecolumn(io, ::Type{Dates.Date}, A)
    return writepadded(io, map(Arrow.date2unix, A))
end
# Timestamp
function writecolumn(io, ::Type{Dates.DateTime}, A)
    return writepadded(io, map(Arrow.datetime2unix, A))
end
function writecolumn(io, ::Type{DateTime}, A::Vector{Union{DateTime,Missing}})
    writecolumn(io, DateTime, map(x->ifelse(ismissing(x),Dates.unix2datetime(0),x), A))
end
function writecolumn(io, ::Type{Date}, A::Vector{Union{DateTime,Missing}})
    zerodate = Date(Dates.unix2datetime(0))
    writecolumn(io, Date, map(x->ifelse(ismissing(x),zerodate,x), A))
end
# other primitive T
writecolumn(io, ::Type{T}, A::Vector{Union{Missing, T}}) where {T} = writecolumn(io, T, map(x->ifelse(ismissing(x),zero(T),x), A))
writecolumn(io, ::Type{T}, A) where {T} = writepadded(io, A)

# List types
valuelength(val::T) where {T} = sizeof(string(val))
valuelength(val::String) = sizeof(val)
valuelength(val::WeakRefString{UInt8}) = val.len
valuelength(val::Missing) = 0

writevalue(io, val::T) where {T} = Base.write(io, string(val))
writevalue(io, val::Missing) = 0
writevalue(io, val::String) = Base.write(io, val)

function writecolumn(io, ::Type{T}, arr::Union{WeakRefStringArray{WeakRefString{UInt8}}, Vector{T}, Vector{Union{Missing, T}}}) where {T <: Union{Vector{UInt8}, AbstractString}}
    len = length(arr)
    off = 0
    offsets = zeros(Int32, len + 1)
    for ind = 1:length(arr)
        v = arr[ind]
        off += Feather.valuelength(v)
        offsets[ind + 1] = off
    end
    total_bytes = Feather.writepadded(io, view(reinterpret(UInt8, offsets), 1:length(offsets) * sizeof(Int32)))
    total_bytes += offsets[len+1]
    for val in arr
        Feather.writevalue(io, val)
    end
    diff = Feather.paddedlength(offsets[len+1]) - offsets[len+1]
    if diff > 0
        Base.write(io, zeros(UInt8, diff))
        total_bytes += diff
    end
    return total_bytes
end

writenulls(io, A, null_count, len, total_bytes) = return total_bytes
function writenulls(io, A::Vector{Union{T, Missing}}, null_count, len, total_bytes) where {T}
    # write out null bitmask
    if null_count > 0
        null_bytes = Feather.bytes_for_bits(len)
        bytes = BitArray(Bool[!ismissing(x) for x in A])
        total_bytes = writepadded(io, view(reinterpret(UInt8, bytes.chunks), 1:null_bytes))
    end
    return total_bytes
end
function writenulls(io, A::T, null_count, len, total_bytes) where {T <: CategoricalArray}
    # write out null bitmask
    if null_count > 0
        null_bytes = Feather.bytes_for_bits(len)
        bytes = BitArray(map(!, A.refs .== 0))
        total_bytes = writepadded(io, view(reinterpret(UInt8, bytes.chunks), 1:null_bytes))
    end
    return total_bytes
end

"DataStreams Sink implementation for feather-formatted binary files"
mutable struct Sink{T} <: Data.Sink
    ctable::Metadata.CTable
    file::String
    io::IOBuffer
    description::String
    metadata::String
    df::T
end

function Sink(file::AbstractString, schema::Data.Schema=Data.Schema(), ::Type{T}=Data.Column, existing=missing;
              description::AbstractString="", metadata::AbstractString="",
              append::Bool=false, reference::Vector{UInt8}=UInt8[],) where {T<:Data.StreamType}
    if !ismissing(existing)
        df = DataFrame(schema, T, append, existing; reference=reference)
    else
        if append
            df = Feather.read(file)
        else
            df = DataFrame(schema, T, append; reference=reference)
        end
    end
    if append
        schema.rows += length(df.columns) > 0 ? length(df.columns[1]) : 0
    end
    io = IOBuffer()
    Feather.writepadded(io, FEATHER_MAGIC_BYTES)
    return Sink(Metadata.CTable("", 0, Metadata.Column[], VERSION, ""), file, io, description, metadata, df)
end

# DataStreams interface
function Sink(sch::Data.Schema, ::Type{T}, append::Bool, file::AbstractString; reference::Vector{UInt8}=UInt8[], kwargs...) where T
    sink = Sink(file, sch, T; append=append, reference=reference, kwargs...)
    return sink
end

function Sink(sink, sch::Data.Schema, ::Type{T}, append::Bool; reference::Vector{UInt8}=UInt8[]) where T
    sink = Sink(sink.file, sch, T, sink.df; append=append, reference=reference)
    return sink
end

Data.streamtypes(::Type{Sink}) = [Data.Column, Data.Field]
Data.weakrefstrings(::Type{Sink}) = true

Data.streamto!(sink::Feather.Sink, ::Type{Data.Field}, val::T, row, col, kr::Type{Val{S}}) where {T, S} = Data.streamto!(sink.df, Data.Field, val, row, col, kr)
Data.streamto!(sink::Feather.Sink, ::Type{Data.Column}, column::T, row, col, kr::Type{Val{S}}) where {T, S} = Data.streamto!(sink.df, Data.Column, column, row, col, kr)

function Data.close!(sink::Feather.Sink)
    header = sink.df.header
    data = sink.df
    io = sink.io
    # write out arrays, building each array's metadata as we go
    rows = length(header) > 0 ? length(data.columns[1]) : 0
    columns = Feather.Metadata.Column[]
    for (i, name) in enumerate(header)
        arr = data.columns[i]
        total_bytes = 0
        offset = position(io)
        null_count = Feather.nullcount(arr)
        len = length(arr)
        total_bytes = Feather.writenulls(io, arr, null_count, len, total_bytes)
        # write out array values
        TT = Missings.T(eltype(arr))
        total_bytes += Feather.writecolumn(io, TT, arr)
        values = Feather.Metadata.PrimitiveArray(Feather.feathertype(TT), Feather.Metadata.PLAIN, offset, len, null_count, total_bytes)
        push!(columns, Feather.Metadata.Column(String(name), values, Feather.getmetadata(io, TT, arr), String("")))
    end
    # write out metadata
    ctable = Metadata.CTable(sink.description, rows, columns, VERSION, sink.metadata)
    meta = FlatBuffers.build!(ctable)
    rng = (meta.head + 1):length(meta.bytes)
    writepadded(io, view(meta.bytes, rng))
    # write out metadata size
    Base.write(io, Int32(length(rng)))
    # write out final magic bytes
    Base.write(io, FEATHER_MAGIC_BYTES)
    len = position(io)
    open(sink.file, "w") do f
        Base.write(f, view(io.data, 1:len))
    end
    sink.io = IOBuffer()
    sink.ctable = ctable
    return sink
end

"""
`Feather.write{T <: Data.Source}(io, source::Type{T}, source_args...)` => `Feather.Sink`

`Feather.write(io, source::Data.Source)` => `Feather.Sink`


Write a `Data.Source` out to disk as a feather-formatted binary file. The two methods allow the passing of a
fully constructed `Data.Source` (2nd method), or the type of Source and any necessary positional arguments (1st method).

Keyword arguments:

  * `append::Bool=false`: indicates whether the `source` argument should be appended to an existing feather file; note that column types between the `source` argument and feather file must match to allow appending
  * `transforms`: a `Dict{Int,Function}` or `Dict{String,Function}` that provides transform functions to be applied to source fields or columns as they are streamed to the feather file; note that feather sinks can be receive data field-by-field or entire columns at a time, so transform functions need to operate on scalars or vectors appropriately, depending on the `source` argument's allowed streaming types; by default, a `Feather.Sink` will stream entire columns at a time, so a transform function would take a single `NullableVector{T}` argument and return an equal-length `NullableVector`

Examples:

```julia
df = DataFrame(...)
Feather.write("shiny_new_feather_file.feather", df)

Feather.write("sqlite_query_result.feather", SQLite.Source, db, "select * from cool_table")
```
"""
function write end

function write(io::AbstractString, ::Type{T}, args...; append::Bool=false, transforms::Dict=Dict{Int,Function}(), kwargs...) where {T}
    sink = Data.stream!(T(args...), Feather.Sink, io; append=append, transforms=transforms, kwargs...)
    return Data.close!(sink)
end
function write(io::AbstractString, source; append::Bool=false, transforms::Dict=Dict{Int,Function}(), kwargs...)
    sink = Data.stream!(source, Feather.Sink, io; append=append, transforms=transforms, kwargs...)
    return Data.close!(sink)
end

write(sink::Sink, ::Type{T}, args...; append::Bool=false, transforms::Dict=Dict{Int,Function}()) where {T} = (sink = Data.stream!(T(args...), sink; append=append, transforms=transforms); return Data.close!(sink))
write(sink::Sink, source; append::Bool=false, transforms::Dict=Dict{Int,Function}()) = (sink = Data.stream!(source, sink; append=append, transforms=transforms); return Data.close!(sink))

end # module
