# Import CUDA library
import CUDA

# Import ML library
import Flux

# Import AutoDiff backends
import ChainRulesCore
import TaylorDiff

# Import library to find nearest neighbors
import NearestNeighbors
import Clustering
import Distances

# Import library to use Ellipsis Notation
using EllipsisNotation

# Import lobary to conditionally load functions when GPUs are available
import Requires

# Import library for random sampling
import Distributions
import StatsBase
import Random

# Import library for basic math
import LinearAlgebra

# Export functions
export shuffle_data, cycle_anneal, locality_sampler, vec_to_ltri,
    centroids_kmeans

## =============================================================================

@doc raw"""
    `step_scheduler(epoch, epoch_change, learning_rates)`

Simple function to define different learning rates at specified epochs.

# Arguments
- `epoch::Int`: Epoch at which to define learning rate.
- `epoch_change::Vector{<:Int}`: Number of epochs at which to change learning
  rate. It must include the initial learning rate!
- `learning_rates::Vector{<:AbstractFloat}`: Learning rate value for the epoch
  range. Must be the same length as `epoch_change`

# Returns
- `η::Abstr`
"""
function step_scheduler(
    epoch::Int,
    epoch_change::AbstractVector{<:Int},
    learning_rates::AbstractVector{<:AbstractFloat}
)
    # Check that arrays are of the same length
    if length(epoch_change) != length(learning_rates)
        error("epoch_change and learning_rates must be of the same length")
    end # if

    # Sort arrays to make sure it goes in epoch order.
    idx_sort = sortperm(epoch_change)
    sort!(epoch_change)
    learning_rates = learning_rates[idx_sort]

    # Check if there is any rate that belongs to the epoch
    if any(epoch .≤ epoch_change)
        # Return corresponding learning rate
        return first(learning_rates[epoch.≤epoch_change])
    else
        return learning_rates[end]
    end
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    cycle_anneal(
        epoch::Int, 
        n_epoch::Int, 
        n_cycles::Int; 
        frac::AbstractFloat=0.5f0, 
        βmax::Number=1.0f0, 
        βmin::Number=0.0f0, 
        T::Type=Float32
    )

Function that computes the value of the annealing parameter β for a variational
autoencoder as a function of the epoch number according to the cyclical
annealing strategy.

# Arguments
- `epoch::Int`: Epoch on which to evaluate the value of the annealing parameter.
- `n_epoch::Int`: Number of epochs that will be run to train the VAE.
- `n_cycles::Int`: Number of annealing cycles to be fit within the number of
  epochs.

## Optional Arguments
- `frac::AbstractFloat= 0.5f0`: Fraction of the cycle in which the annealing
  parameter β will increase from the minimum to the maximum value.
- `βmax::Number=1.0f0`: Maximum value that the annealing parameter can reach.
- `βmin::Number=0.0f0`: Minimum value that the annealing parameter can reach.
- `T::Type=Float32`: The type of the output. The function will convert the
  output to this type.

# Returns
- `β::T`: Value of the annealing parameter.

# Citation
> Fu, H. et al. Cyclical Annealing Schedule: A Simple Approach to Mitigating KL
> Vanishing. Preprint at http://arxiv.org/abs/1903.10145 (2019).
"""
function cycle_anneal(
    epoch::Int,
    n_epoch::Int,
    n_cycles::Int;
    frac::AbstractFloat=0.5f0,
    βmax::Number=1.0f0,
    βmin::Number=0.0f0,
    T::Type=Float32
)
    # Validate frac
    if !(0 ≤ frac ≤ 1)
        throw(ArgumentError("Frac must be between 0 and 1"))
    end # if

    # Define variable τ that will serve to define the value of β
    τ = mod(epoch - 1, ceil(n_epoch / n_cycles)) / (n_epoch / n_cycles)

    # Compute and return the value of β
    if τ ≤ frac
        return convert(T, (βmax - βmin) * τ / frac + βmin)
    else
        return convert(T, βmax)
    end # if
end # function

# ------------------------------------------------------------------------------

@doc raw"""
`locality_sampler(data, dist_tree, n_primary, n_secondary, k_neighbors;
index=false)`

Algorithm to generate mini-batches based on spatial locality as determined by a
pre-constructed nearest neighbors tree.

# Arguments
- `data::AbstractArray`: An array containing the data points. The data points
  can be of any dimension.
- `dist_tree::NearestNeighbors.NNTree`: `NearestNeighbors.jl` tree used to
  determine the distance between data points.
- `n_primary::Int`: Number of primary points to sample.
- `n_secondary::Int`: Number of secondary points to sample from the neighbors of
  each primary point.
- `k_neighbors::Int`: Number of nearest neighbors from which to potentially
  sample the secondary points.

# Optional Keyword Arguments
- `index::Bool`: If `true`, returns the indices of the selected samples. If
  `false`, returns the `data` corresponding to the indexes. Defaults to `false`.

# Returns
- If `index` is `true`, returns `sample_idx::Vector{Int64}`: Indices of data
  points to include in the mini-batch.
- If `index` is `false`, returns `sample_data::AbstractArray`: The data points
  to include in the mini-batch.

# Description
This sampling algorithm consists of three steps:
1. For each datapoint, determine the `k_neighbors` nearest neighbors using the
   `dist_tree`.
2. Uniformly sample `n_primary` points without replacement from all data points.
3. For each primary point, sample `n_secondary` points without replacement from
   its `k_neighbors` nearest neighbors.

# Examples
```julia
# Pre-constructed NearestNeighbors.jl tree
dist_tree = NearestNeighbors.KDTree(data, metric)
sample_indices = locality_sampler(data, dist_tree, 10, 5, 50)
```

# Citation
> Skafte, N., Jø rgensen, M. & Hauberg, S. ren. Reliable training and estimation
> of variance networks. in Advances in Neural Information Processing Systems
> vol. 32 (Curran Associates, Inc., 2019).
"""
function locality_sampler(
    data::AbstractArray,
    dist_tree::NearestNeighbors.NNTree,
    n_primary::Int,
    n_secondary::Int,
    k_neighbors::Int;
    index::Bool=false
)
    # Check that n_secondary ≤ k_neighbors
    if !(n_secondary ≤ k_neighbors)
        # Report error
        error("n_secondary must be ≤ k_neighbors")
    end # if

    # Sample n_primary primary sampling units with uniform probability without
    # replacement among all N units
    idx_primary = StatsBase.sample(
        1:size(data, ndims(data)), n_primary, replace=false
    )

    # Extract primary sample
    sample_primary = @view data[.., idx_primary]

    # Compute k_nearest neighbors for each of the points
    k_idxs, dists = NearestNeighbors.knn(
        dist_tree, sample_primary, k_neighbors, true
    )

    # For each of the primary sampling units sample n_secondary secondary
    # sampling units among the primary sampling units k_neighbors nearest
    # neighbors with uniform probability without replacement.
    idx_secondary = vcat([
        StatsBase.sample(p, n_secondary, replace=false) for p in k_idxs
    ]...)

    # Return minibatch data
    if index
        return [idx_primary; idx_secondary]
    else
        return @view data[.., [idx_primary; idx_secondary]]
    end # if
end # function

## =============================================================================
# Convert vector to lower triangular matrix
## =============================================================================

@doc raw"""
        vec_to_ltri{T}(diag::AbstractVector{T}, lower::AbstractVector{T})

Convert two one-dimensional vectors into a lower triangular matrix.

# Arguments
- `diag::AbstractVector{T}`: The input vector to be converted into the diagonal
    of the matrix.
- `lower::AbstractVector{T}`: The input vector to be converted into the lower
    triangular part of the matrix. The length of this vector should be a
    triangular number (i.e., the sum of the first `n` natural numbers for some
    `n`).

# Returns
- A lower triangular matrix constructed from `diag` and `lower`.

# Description
This function constructs a lower triangular matrix from two input vectors,
`diag` and `lower`. The `diag` vector provides the diagonal elements of the
matrix, while the `lower` vector provides the elements below the diagonal. The
function uses a comprehension to construct the matrix, with the `lower_index`
function calculating the appropriate index in the `lower` vector for each
element below the diagonal.

# Example
```julia
diag = [1, 2, 3]
lower = [4, 5, 6]
vec_to_ltri(diag, lower)  # Returns a 3x3 lower triangular matrix
```
"""
function vec_to_ltri(
    diag::AbstractVector{T}, lower::AbstractVector{T},
) where {T<:Number}
    # Define dimensionality of the matrix
    n = length(diag)

    # Define a function to calculate the index in the 'lower' array
    lower_index = ChainRulesCore.ignore_derivatives() do
        (i, j) -> (i - 1) * (i - 2) ÷ 2 + j
    end # function

    # Create the matrix using a comprehension
    return reshape(
        [
            i == j ? diag[i] :
            i > j ? lower[lower_index(i, j)] :
            zero(T) for i in 1:n, j in 1:n
        ],
        n, n
    )
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    vec_to_ltri(
        diag::AbstractMatrix{T}, lower::AbstractMatrix{T}
    ) where {T<:Number}

Construct a set of lower triangular matrices from a matrix of diagonal elements
and a matrix of lower triangular elements, each column representing a sample.

# Arguments
- `diag::AbstractMatrix{T}`: A matrix of `T` where each column contains the
    diagonal elements of the matrix for a specific sample.
- `lower::AbstractMatrix{T}`: A matrix of `T` where each column contains the
    elements of the lower triangle of the matrix for a specific sample.

# Returns
- A 3D array of type `T` where each slice along the third dimension is a lower
    triangular matrix with the diagonal and lower triangular elements populated
    from `diag` and `lower` respectively.

# Description
This function constructs a set of lower triangular matrices from two input
matrices, `diag` and `lower`. The `diag` matrix provides the diagonal elements
of the matrices, while the `lower` matrix provides the elements below the
diagonal. The function uses a comprehension to construct the matrices, with the
`lower_index` function calculating the appropriate index in the `lower` matrix
for each element below the diagonal.

# Note
The function assumes that the `diag` and `lower` matrices have the correct
dimensions for the matrices to be constructed. Specifically, `diag` and `lower`
should have `n` rows and `m` columns, where `n` is the dimension of the matrix
and `m` is the number of samples. The `lower` matrix should have `n*(n-1)/2`
non-zero elements per column, corresponding to the lower triangular part of the
matrix.
"""
function vec_to_ltri(
    diag::AbstractMatrix{T}, lower::AbstractMatrix{T}
) where {T<:Number}
    # Extract matrix dimensions and number of samples
    n, cols = size(diag)

    # Check that 'lower' has the correct dimensions
    if size(lower) != (n * (n - 1) ÷ 2, cols)
        error("Dimension mismatch between 'diag' and 'lower' matrices")
    end

    # Define a function to calculate the index in the 'lower' array for each
    # column
    lower_index = ChainRulesCore.ignore_derivatives() do
        (col, i, j) -> (i - 1) * (i - 2) ÷ 2 + j + (col - 1) * (n * (n - 1) ÷ 2)
    end # function

    # Create the 3D tensor using a comprehension
    return reshape(
        [
            i == j ? diag[i, k] :
            i > j ? lower[lower_index(k, i, j)] :
            zero(T) for i in 1:n, j in 1:n, k in 1:cols
        ],
        n, n, cols
    )
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    vec_to_ltri(
        diag::CUDA.CuVecOrMat{T}, lower::CUDA.CuVecOrMat{T}
    ) where {T<:Number}

Construct a set of lower triangular matrices from a matrix of diagonal elements
and a matrix of lower triangular elements, each column representing a sample.

# Arguments
- `diag::CUDA.CuVecOrMat{T}`: A matrix of `T` where each column contains the
    diagonal elements of the matrix for a specific sample.
- `lower::CUDA.CuVecOrMat{T}`: A matrix of `T` where each column contains the
    elements of the lower triangle of the matrix for a specific sample.

# Returns
- A 3D array of type `T` where each slice along the third dimension is a lower
    triangular matrix with the diagonal and lower triangular elements populated
    from `diag` and `lower` respectively.

# Description
This function constructs a set of lower triangular matrices from two input
matrices, `diag` and `lower`. The `diag` matrix provides the diagonal elements
of the matrices, while the `lower` matrix provides the elements below the
diagonal. The function uses a comprehension to construct the matrices, with the
`lower_index` function calculating the appropriate index in the `lower` matrix
for each element below the diagonal.

# Note
The function assumes that the `diag` and `lower` matrices have the correct
dimensions for the matrices to be constructed. Specifically, `diag` and `lower`
should have `n` rows and `m` columns, where `n` is the dimension of the matrix
and `m` is the number of samples. The `lower` matrix should have `n*(n-1)/2`
non-zero elements per column, corresponding to the lower triangular part of the
matrix.
"""
function vec_to_ltri(
    diag::CUDA.CuVecOrMat{T}, lower::CUDA.CuVecOrMat{T}
) where {T<:Number}
    return CUDA.cu(vec_to_ltri(diag |> Flux.cpu, lower |> Flux.cpu))
end # function

## =============================================================================
# Vector Matrix Vector multiplication
## =============================================================================

@doc raw"""
    vec_mat_vec_batched(
        v::AbstractVector, 
        M::AbstractMatrix, 
        w::AbstractVector
    )

Compute the product of a vector, a matrix, and another vector in the form v̲ᵀ
M̲̲ w̲.

This function takes two vectors `v` and `w`, and a matrix `M`, and computes the
product v̲ M̲̲ w̲. This function is added for consistency when calling multiple
dispatch.

# Arguments
- `v::AbstractVector`: A `d` dimensional vector.
- `M::AbstractMatrix`: A `d×d` matrix.
- `w::AbstractVector`: A `d` dimensional vector.

# Returns
A scalar which is the result of the product v̲ M̲̲ w̲ for the corresponding
vectors and matrix.

# Notes
This function uses the `LinearAlgebra.dot` function to perform the
multiplication of the matrix `M` with the vector `w`. The resulting vector is
then element-wise multiplied with the vector `v` and summed over the dimensions
to obtain the final result. This function is added for consistency when calling
multiple dispatch.
"""
function vec_mat_vec_batched(
    v::AbstractVector,
    M::AbstractMatrix,
    w::AbstractVector
)
    return LinearAlgebra.dot(v, M, w)
end # for

# ------------------------------------------------------------------------------

@doc raw"""
    vec_mat_vec_batched(
        v::AbstractMatrix, 
        M::AbstractArray, 
        w::AbstractMatrix
    )

Compute the batched product of vectors and matrices in the form v̲ᵀ M̲̲ w̲.

This function takes two matrices `v` and `w`, and a 3D array `M`, and computes
the batched product v̲ M̲̲ w̲. The computation is performed in a broadcasted
manner using the `Flux.batched_vec` function.

# Arguments
- `v::AbstractMatrix`: A `d×n` matrix, where `d` is the dimension of the vectors
  and `n` is the number of vectors.
- `M::AbstractArray`: A `d×d×n` array, where `d` is the dimension of the
  matrices and `n` is the number of matrices.
- `w::AbstractMatrix`: A `d×n` matrix, where `d` is the dimension of the vectors
  and `n` is the number of vectors.

# Returns
An `n` dimensional array where each element is the result of the product v̲ M̲̲
w̲ for the corresponding vectors and matrix.

# Notes
This function uses the `Flux.batched_vec` function to perform the batched
multiplication of the matrices in `M` with the vectors in `w`. The resulting
vectors are then element-wise multiplied with the vectors in `v` and summed over
the dimensions to obtain the final result.
"""
function vec_mat_vec_batched(
    v::AbstractMatrix,
    M::AbstractArray,
    w::AbstractMatrix
)
    # Compute v̲ M̲̲ w̲ in a broadcasted manner
    return vec(sum(v .* Flux.batched_vec(M, w), dims=1))
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    vec_mat_vec_loop(
        v::AbstractVector, 
        M::AbstractMatrix, 
        w::AbstractVector
    )

Compute the product of a vector, a matrix, and another vector in the form v̲ᵀ
M̲̲ w̲ using loops.

This function takes two vectors `v` and `w`, and a matrix `M`, and computes the
product v̲ M̲̲ w̲ using nested loops. This method might be slower than using
batched operations, but it is needed when performing differentiation with
`Zygote.jl` over `TaylorDiff.jl`.

# Arguments
- `v::AbstractVector`: A `d` dimensional vector.
- `M::AbstractMatrix`: A `d×d` matrix.
- `w::AbstractVector`: A `d` dimensional vector.

# Returns
A scalar which is the result of the product v̲ M̲̲ w̲ for the corresponding
vectors and matrix.

# Notes
This function uses nested loops to perform the multiplication of the matrix `M`
with the vector `w`. The resulting vector is then element-wise multiplied with
the vector `v` and summed over the dimensions to obtain the final result. This
method might be slower than using batched operations, but it is needed when
performing differentiation with `Zygote.jl` over `TaylorDiff.jl`.
"""
function vec_mat_vec_loop(
    v::AbstractVector,
    M::AbstractMatrix,
    w::AbstractVector
)
    # Check dimensions to see if the multiplication is possible
    if size(v, 1) ≠ size(M, 1) || size(M, 2) ≠ size(w, 1)
        throw(DimensionMismatch("Dimensions of vectors and matrices do not match"))
    end # if
    # Compute v̲ M̲̲ w̲ in a loop
    return sum(
        begin
            v[i] * M[i, j] * w[j]
        end
        for i in axes(v, 1)
        for j in axes(w, 1)
    )
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    vec_mat_vec_loop(
        v::AbstractMatrix, 
        M::AbstractArray, 
        w::AbstractMatrix
    )

Compute the product of vectors and matrices in the form v̲ᵀ M̲̲ w̲ using loops.

This function takes two matrices `v` and `w`, and a 3D array `M`, and computes
the product v̲ M̲̲ w̲ using nested loops. This method might be slower than using
batched operations, but it is needed when performing differentiation with
`Zygote.jl` over `TaylorDiff.jl`.

# Arguments
- `v::AbstractMatrix`: A `d×n` matrix, where `d` is the dimension of the vectors
  and `n` is the number of vectors.
- `M::AbstractArray`: A `d×d×n` array, where `d` is the dimension of the
  matrices and `n` is the number of matrices.
- `w::AbstractMatrix`: A `d×n` matrix, where `d` is the dimension of the vectors
  and `n` is the number of vectors.

# Returns
A `1×n` matrix where each element is the result of the product v̲ M̲̲ w̲ for the
corresponding vectors and matrix.

# Notes
This function uses nested loops to perform the multiplication of the matrices in
`M` with the vectors in `w`. The resulting vectors are then element-wise
multiplied with the vectors in `v` and summed over the dimensions to obtain the
final result. This method might be slower than using batched operations, but it
is needed when performing differentiation with `Zygote.jl` over `TaylorDiff.jl`.
"""
function vec_mat_vec_loop(
    v::AbstractMatrix,
    M::AbstractArray{<:Any,3},
    w::AbstractMatrix
)
    # Check dimensions to see if the multiplication is possible
    if size(v, 1) ≠ size(M, 1) || size(M, 2) != size(w, 1)
        throw(DimensionMismatch("Dimensions of vectors and matrices do not match"))
    end # if

    # Compute v̲ M̲̲ w̲ in a loop
    [
        begin
            sum(
                begin
                    v[i, k] *
                    M[i, j, k] *
                    w[j, k]
                end
                for i in axes(v, 1)
                for j in axes(w, 1)
            )
        end for k in axes(v, 2)
    ]
end # function

# function vec_mat_vec_loop(
#     v::CUDA.CuVecOrMat,
#     M::CUDA.CuArray,
#     w::CUDA.CuVecOrMat
# )
#     # Sent arrays to CPU
#     vec_mat_vec_loop(Flux.cpu(v), Flux.cpu(M), Flux.cpu(w)) |> Flux.gpu
# end # function

## =============================================================================
# Define centroids via k-means
## =============================================================================

@doc raw"""
    centroids_kmeans(
        x::AbstractMatrix, 
        n_centroids::Int; 
        assign::Bool=false
    )

Perform k-means clustering on the input and return the centers. This function
can be used to down-sample the number of points used when computing the metric
tensor in training a Riemannian Hamiltonian Variational Autoencoder (RHVAE).

# Arguments
- `x::AbstractMatrix`: The input data. Rows represent individual
  samples.
- `n_centroids::Int`: The number of centroids to compute.

# Optional Keyword Arguments
- `assign::Bool=false`: If true, also return the assignments of each point to a
  centroid.

# Returns
- If `assign` is false, returns a matrix where each column is a centroid.
- If `assign` is true, returns a tuple where the first element is the matrix of
  centroids and the second element is a vector of assignments.

# Examples
```julia
data = rand(100, 10)
centroids = centroids_kmeans(data, 5)
```
"""
function centroids_kmeans(
    x::AbstractMatrix,
    n_centroids::Int;
    assign::Bool=false
)
    # Perform k-means clustering on the input and return the centers
    if assign
        # Compute clustering
        clustering = Clustering.kmeans(x, n_centroids)
        # Return centers and assignments
        return (clustering.centers, Clustering.assignments(clustering))
    else
        # Return centers
        return Clustering.kmeans(x, n_centroids).centers
    end # if
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    centroids_kmeans(
        x::AbstractArray, 
        n_centroids::Int; 
        reshape_centroids::Bool=true, 
        assign::Bool=false
    )

Perform k-means clustering on the input and return the centers. This function
can be used to down-sample the number of points used when computing the metric
tensor in training a Riemannian Hamiltonian Variational Autoencoder (RHVAE).

The input data is flattened into a matrix before performing k-means clustering.
This is done because k-means operates on a set of data points in a vector space
and cannot handle multi-dimensional arrays. Flattening the input ensures that
the k-means algorithm can process the data correctly.

By default, the output centroids are reshaped back to the original input shape.
This is controlled by the `reshape_centroids` argument.

# Arguments
- `x::AbstractArray`: The input data. It can be a multi-dimensional
  array where the last dimension represents individual samples.
- `n_centroids::Int`: The number of centroids to compute.

# Optional Keyword Arguments
- `reshape_centroids::Bool=true`: If true, reshape the output centroids back to
  the original input shape.
- `assign::Bool=false`: If true, also return the assignments of each point to a
  centroid.

# Returns
- If `assign` is false, returns a matrix where each column is a centroid.
- If `assign` is true, returns a tuple where the first element is the matrix of
  centroids and the second element is a vector of assignments.

# Examples
```julia
data = rand(100, 10)
centroids = centroids_kmeans(data, 5)
```
"""
function centroids_kmeans(
    x::AbstractArray,
    n_centroids::Int;
    reshape_centroids::Bool=true,
    assign::Bool=false
)
    # Flatten input into matrix
    x_flat = Flux.flatten(x)

    # Check if output should be reshaped
    if reshape_centroids
        # Perform k-means clustering on the input and return the centers
        if assign
            # Compute clustering
            clustering = Clustering.kmeans(x_flat, n_centroids)
            # Extract centeres
            centers = clustering.centers
            # Reshape centers
            centers = reshape(centers, size(x)[1:end-1]..., n_centroids)
            # Return centers and assignments
            return (centers, Clustering.assignments(clustering))
        else
            # Compute clustering
            clustering = Clustering.kmeans(x_flat, n_centroids)
            # Extract centeres
            centers = clustering.centers
            # Reshape centers
            centers = reshape(centers, size(x)[1:end-1]..., n_centroids)
            # Return centers
            return centers
        end # if
    else
        # Perform k-means clustering on the input and return the centers
        if assign
            # Compute clustering
            clustering = Clustering.kmeans(x_flat, n_centroids)
            # Return centers and assignments
            return (clustering.centers, Clustering.assignments(clustering))
        else
            # Return centers
            return Clustering.kmeans(x_flat, n_centroids).centers
        end # if
    end # if
end # function

## =============================================================================
# Define centroids via k-medoids
## =============================================================================

@doc raw"""
        centroids_kmedoids(
            x::AbstractMatrix, n_centroids::Int; assign::Bool=false
        )

Perform k-medoids clustering on the input and return the centers. This function
can be used to down-sample the number of points used when computing the metric
tensor in training a Riemannian Hamiltonian Variational Autoencoder (RHVAE).

# Arguments
- `x::AbstractMatrix`: The input data. Rows represent individual
  samples.
- `n_centroids::Int`: The number of centroids to compute.
- `dist::Distances.PreMetric=Distances.Euclidean()`: The distance metric to use
  when computing the pairwise distance matrix.

# Optional Keyword Arguments
- `assign::Bool=false`: If true, also return the assignments of each point to a
  centroid.

# Returns
- If `assign` is false, returns a matrix where each column is a centroid.
- If `assign` is true, returns a tuple where the first element is the matrix of
  centroids and the second element is a vector of assignments.

# Examples
```julia
data = rand(100, 10)
centroids = centroids_kmedoids(data, 5)
```
"""
function centroids_kmedoids(
    x::AbstractMatrix,
    n_centroids::Int,
    dist::Distances.PreMetric=Distances.Euclidean();
    assign::Bool=false
)
    # Compute pairwise distance matrix
    dist_matrix = Distances.pairwise(dist, x, dims=2)
    # Perform k-means clustering on the input and return the centers
    if assign
        # Compute clustering
        clustering = Clustering.kmedoids(dist_matrix, n_centroids)
        # Return centers and assignments
        return (x[:, clustering.medoids], clustering.assignments)
    else
        # Return centers
        return x[:, Clustering.kmedoids(dist_matrix, n_centroids).medoids]
    end # if
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    centroids_kmedoids(
        x::AbstractArray,
        n_centroids::Int,
        dist::Distances.PreMetric=Distances.Euclidean();
        assign::Bool=false
    )

Perform k-medoids clustering on the input and return the centers. This function
can be used to down-sample the number of points used when computing the metric
tensor in training a Riemannian Hamiltonian Variational Autoencoder (RHVAE).

# Arguments
- `x::AbstractArray`: The input data. The last dimension of `x` should
  contain each of the samples that should be clustered.
- `n_centroids::Int`: The number of centroids to compute.
- `dist::Distances.PreMetric=Distances.Euclidean()`: The distance metric to use
  for the clustering. Defaults to Euclidean distance.

# Optional Keyword Arguments
- `assign::Bool=false`: If true, also return the assignments of each point to a
  centroid.

# Returns
- If `assign` is false, returns an array where each column is a centroid.
- If `assign` is true, returns a tuple where the first element is the array of
  centroids and the second element is a vector of assignments.

# Examples
```julia
data = rand(10, 100)
centroids = centroids_kmedoids(data, 5)
```
"""
function centroids_kmedoids(
    x::AbstractArray,
    n_centroids::Int,
    dist::Distances.PreMetric=Distances.Euclidean();
    assign::Bool=false
)
    # Compute pairwise distance matrix by collecting slices with respect to the
    # last dimension
    dist_matrix = Distances.pairwise(dist, collect(eachslice(x, dims=ndims(x))))
    # Perform k-means clustering on the input and return the centers
    if assign
        # Compute clustering
        clustering = Clustering.kmedoids(dist_matrix, n_centroids)
        # Return centers and assignments
        return (x[.., clustering.medoids], clustering.assignments)
    else
        # Return centers
        return x[.., Clustering.kmedoids(dist_matrix, n_centroids).medoids]
    end # if
end # function

# =============================================================================
# Computing the log determinant of a matrix via Cholesky decomposition.
# =============================================================================

"""
    slogdet(A::AbstractMatrix{T}; check::Bool=false) where {T<:Number}

Compute the log determinant of a positive-definite matrix `A`.

# Arguments
- `A::AbstractMatrix{T}`: A positive-definite matrix whose log determinant is to
  be computed.
- `check::Bool=false`: A flag that determines whether to check if the input
  matrix `A` is positive-definite. Defaults to `false`.

# Returns
- The log determinant of `A`.

# Description
This function computes the log determinant of a positive-definite matrix `A`. It
first computes the Cholesky decomposition of `A`, and then calculates the log
determinant as twice the sum of the log of the diagonal elements of the lower
triangular matrix from the Cholesky decomposition.

# Conditions
The input matrix `A` must be a positive-definite matrix, i.e., it must be
symmetric and all its eigenvalues must be positive. If `check` is set to `true`,
the function will throw an error if `A` is not positive-definite.

# Example
```julia
A = rand(3, 3)
A = A * A'  # make A positive-definite
println(slogdet(A))
```
"""
function slogdet(
    A::AbstractMatrix{T}; check::Bool=false
) where {T<:Number}
    # Compute the Cholesky decomposition of A. 
    chol = LinearAlgebra.cholesky(A; check=check)
    # compute the log determinant of A as the sum of the log of the diagonal
    # elements of the Cholesky decomposition
    return 2 * sum(log.(LinearAlgebra.diag(chol.L)))
end # function

# ------------------------------------------------------------------------------

"""
    slogdet(A::AbstractArray{T,3}; check::Bool=false) where {T<:Number}

Compute the log determinant of each 2D slice along the third dimension of a 3D
array `A`, where each 2D slice is a positive-definite matrix.

# Arguments
- `A::AbstractArray{T,3}`: A 3D array whose 2D slices along the third dimension
  are positive-definite matrices whose log determinants are to be computed.
- `check::Bool=false`: A flag that determines whether to check if each 2D slice
  of the input array `A` is positive-definite. Defaults to `false`.

# Returns
- A 1D array containing the log determinant of each 2D slice of `A`.

# Description
This function computes the log determinant of each 2D slice along the third
dimension of a 3D array `A`. It first computes the Cholesky decomposition of
each 2D slice, and then calculates the log determinant as twice the sum of the
log of the diagonal elements of the lower triangular matrix from the Cholesky
decomposition.

# Conditions
Each 2D slice of the input array `A` along the third dimension must be a
positive-definite matrix, i.e., it must be symmetric and all its eigenvalues
must be positive. If `check` is set to `true`, the function will throw an error
if any 2D slice is not positive-definite.

# Note
This function uses a list comprehension to compute the Cholesky decomposition on
each slice. Therefore, the function is not performed on the GPU. This might
change in the future if a batched Cholesky decomposition is implemented.

# Example
```julia
A = rand(3, 3, 3)
A = A .* A'  # make each 2D slice of A positive-definite
println(slogdet(A))
```
"""
function slogdet(
    A::AbstractArray{T,3}; check::Bool=false
) where {T<:Number}
    # Compute the Cholesky decomposition of each slice of A. 
    chol = [
        begin
            LinearAlgebra.cholesky(x; check=check).L
        end for x in eachslice(A, dims=3)
    ]

    # compute the log determinant of each slice of A as the sum of the log of
    # the diagonal elements of the Cholesky decomposition
    return [
        begin
            2 * sum(log.(LinearAlgebra.diag(c)))
        end for c in chol
    ] |> Flux.gpu
end # function

## =============================================================================
# Defining random number generators 
## =============================================================================

@doc raw"""
    sample_MvNormalCanon(Σ⁻¹::AbstractMatrix{T}) where {T<:Number}

Draw a random sample from a multivariate normal distribution in canonical form.

# Arguments
- `Σ⁻¹::AbstractMatrix{T}`: The precision matrix (inverse of the covariance
  matrix) of the multivariate normal distribution.

# Returns
- A random sample drawn from the multivariate normal distribution specified by
  the input precision matrix.
"""
function sample_MvNormalCanon(
    Σ⁻¹::AbstractMatrix
)
    # Invert the precision matrix
    Σ = LinearAlgebra.inv(Σ⁻¹ |> Flux.cpu)

    # Cholesky decomposition of the covariance matrix
    chol = LinearAlgebra.cholesky(Σ, check=false)

    # Define sample type
    if !(eltype(Σ⁻¹) <: AbstractFloat)
        T = Float32
    else
        T = eltype(Σ⁻¹)
    end # if

    # Sample from standard normal distribution
    r = randn(T, size(Σ⁻¹, 1))

    # Return sample multiplied by the Cholesky decomposition
    return chol.L * r |> Flux.gpu
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    sample_MvNormalCanon(Σ⁻¹::AbstractArray{T,3}) where {T<:Number}

Draw a random sample from a multivariate normal distribution in canonical form.

# Arguments
- `Σ⁻¹::AbstractArray{T,3}`: The precision matrix (inverse of the covariance
  matrix) of the multivariate normal distribution. Each slice of the 3D tensor
  corresponds to one precision matrix.

# Returns
- A random sample drawn from the multivariate normal distributions specified by
  the input precision matrices.
"""
function sample_MvNormalCanon(
    Σ⁻¹::AbstractArray{<:Number,3}
)
    # Extract dimensions
    dim = size(Σ⁻¹, 1)
    # Extract number of samples
    n_sample = size(Σ⁻¹, 3)

    # Invert the precision matrix
    Σ = LinearAlgebra.inv.(eachslice(Σ⁻¹ |> Flux.cpu, dims=3))

    # Cholesky decomposition of the covariance matrix
    chol = reduce(
        (x, y) -> cat(x, y, dims=3),
        [
            begin
                LinearAlgebra.cholesky(slice, check=false).L
            end for slice in Σ
        ]
    )

    # Define sample type
    if !(eltype(Σ⁻¹) <: AbstractFloat)
        T = Float32
    else
        T = eltype(Σ⁻¹)
    end # if

    # Sample from standard normal distribution
    r = randn(T, dim, n_sample)

    # Return sample multiplied by the Cholesky decomposition
    return Flux.batched_vec(chol, r) |> Flux.gpu
end # function

# Set ChainRulesCore to ignore the function when computing gradients
ChainRulesCore.@ignore_derivatives sample_MvNormalCanon

## =============================================================================
# Define finite difference gradient function
## =============================================================================

@doc raw"""
    unit_vector(x::AbstractVector, i::Int)

Create a unit vector of the same length as `x` with the `i`-th element set to 1.

# Arguments
- `x::AbstractVector`: The vector whose length is used to determine the
  dimension of the unit vector.
- `i::Int`: The index of the element to be set to 1.

# Returns
- A unit vector of type `eltype(x)` and length equal to `x` with the `i`-th
  element set to 1.

# Description
This function creates a unit vector of the same length as `x` with the `i`-th
element set to 1. All other elements are set to 0.

# Note
This function is marked with the `@ignore_derivatives` macro from the
`ChainRulesCore` package, which means that all AutoDiff backends will ignore any
call to this function when computing gradients.
"""
function unit_vector(x::AbstractVector, i::Int)
    # Extract type of elements in the vector
    T = eltype(x)
    # Build unit vector
    return [j == i ? one(T) : zero(T) for j in 1:length(x)]
end # function

@doc raw"""
    unit_vector(x::AbstractMatrix, i::Int)

Create a unit vector of the same length as the number of rows in `x` with the
`i`-th element set to 1.

# Arguments
- `x::AbstractMatrix`: The matrix whose number of rows is used to determine the
  dimension of the unit vector.
- `i::Int`: The index of the element to be set to 1.

# Returns
- A unit vector of type `eltype(x)` and length equal to the number of rows in
  `x` with the `i`-th element set to 1.

# Description
This function creates a unit vector of the same length as the number of rows in
`x` with the `i`-th element set to 1. All other elements are set to 0. 

# Note
This function is marked with the `@ignore_derivatives` macro from the
`ChainRulesCore` package, which means that all AutoDiff backends will ignore any
call to this function when computing gradients.
"""
function unit_vector(x::AbstractMatrix, i::Int)
    # Extract type of elements in the vector
    T = eltype(x)
    # Build unit vector
    return [j == i ? one(T) : zero(T) for j in axes(x, 1)]
end # function

# Set Chainrulescore to ignore the function when computing gradients
ChainRulesCore.@ignore_derivatives unit_vector

# ------------------------------------------------------------------------------

@doc raw"""
    unit_vectors(x::AbstractVector)

Create a vector of unit vectors based on the length of `x`.

# Arguments
- `x::AbstractVector`: The vector whose length is used to determine the
  dimension of the unit vectors.

# Returns
- A vector of unit vectors. Each unit vector has the same length as `x` and has
  a single `1` at the position corresponding to its index in the returned
  vector, with all other elements set to `0`.

# Description
This function creates a vector of unit vectors based on the length of `x`. Each
unit vector has the same length as `x` and has a single `1` at the position
corresponding to its index in the returned vector, with all other elements set
to `0`.

# Note
This function is marked with the `@ignore_derivatives` macro from the
`ChainRulesCore` package, which means that all AutoDiff backends will ignore any
call to this function when computing gradients.
"""
function unit_vectors(x::AbstractVector)
    return [unit_vector(x, i) for i in 1:length(x)] |> Flux.gpu
end # function

# ------------------------------------------------------------------------------

@doc raw"""
        unit_vectors(x::AbstractMatrix)

Create a matrix where each column is a unit vector of the same length as the
number of rows in `x`.

# Arguments
- `x::AbstractMatrix`: The matrix whose number of rows is used to determine the
  dimension of the unit vectors.

# Returns
- A vector of matrices where each entry is a matrix containing all unit vectors
  for a single vector. Each unit vector has a single `1` at the position
  corresponding to its index in the column, with all other elements set to `0`.

# Description
This function creates a matrix where each column is a unit vector of the same
length as the number of rows in `x`. Each unit vector has a single `1` at the
position corresponding to its index in the column, with all other elements set
to `0`.

# Note
This function is marked with the `@ignore_derivatives` macro from the
`ChainRulesCore` package, which means that all AutoDiff backends will ignore any
call to this function when computing gradients.
"""
function unit_vectors(x::AbstractMatrix)
    vectors = [
        reduce(hcat, fill(unit_vector(x, i), size(x, 2)))
        for i in 1:size(x, 1)
    ]
    return vectors |> Flux.gpu
end # function

# Set Chainrulescore to ignore the function when computing gradients
ChainRulesCore.@ignore_derivatives unit_vectors

# ------------------------------------------------------------------------------

@doc raw"""
    finite_difference_gradient(
        f::Function,
        x::AbstractVecOrMat;
        fdtype::Symbol=:central
    )

Compute the finite difference gradient of a function `f` at a point `x`.

# Arguments
- `f::Function`: The function for which the gradient is to be computed. This
  function must return a scalar value.
- `x::AbstractVecOrMat`: The point at which the gradient is to be computed. Can
  be a vector or a matrix. If a matrix, each column represents a point where the
  function f is to be evaluated and the derivative computed.

# Optional Keyword Arguments
- `fdtype::Symbol=:central`: The finite difference type. It can be either
  `:forward` or `:central`. Defaults to `:central`.

# Returns
- A vector or a matrix representing the gradient of `f` at `x`, depending on the
  input type of `x`.

# Description
This function computes the finite difference gradient of a function `f` at a
point `x`. The gradient is a vector or a matrix where the `i`-th element is the
partial derivative of `f` with respect to the `i`-th element of `x`.

The partial derivatives are computed using the forward or central difference
formula, depending on the `fdtype` argument:

- Forward difference formula: ∂f/∂xᵢ ≈ [f(x + ε * eᵢ) - f(x)] / ε
- Central difference formula: ∂f/∂xᵢ ≈ [f(x + ε * eᵢ) - f(x - ε * eᵢ)] / 2ε

where ε is the step size and eᵢ is the `i`-th unit vector.
"""
function finite_difference_gradient(
    f::Function,
    x::AbstractVecOrMat;
    fdtype::Symbol=:central,
)
    # Check that mode is either :forward or :central
    if !(fdtype in (:forward, :central))
        error("fdtype must be either :forward or :central")
    end # if

    # Check fdtype
    if fdtype == :forward
        # Define step size
        ε = √(eps(eltype(x)))
        # Generate unit vectors times step size for each element of x
        Δx = unit_vectors(x) .* ε
        # Compute the finite difference gradient for each element of x
        grad = (f.(Ref(x) .+ Δx) .- f(x)) ./ ε
    else
        # Define step size
        ε = ∛(eps(eltype(x)))
        # Generate unit vectors times step size for each element of x
        Δx = unit_vectors(x) .* ε
        # Compute the finite difference gradient for each element of x
        grad = (f.(Ref(x) .+ Δx) - f.(Ref(x) .- Δx)) ./ (2ε)
    end # if

    if typeof(x) <: AbstractVector
        return grad
    elseif typeof(x) <: AbstractMatrix
        return permutedims(reduce(hcat, grad), [2, 1])
    end # if
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    finite_difference_gradient(
        f::Function,
        x::CUDA.CuVecOrMat;
        fdtype::Symbol=:central
    )

Compute the finite difference gradient of a function `f` at a point `x` on GPUs.

# Arguments
- `f::Function`: The function for which the gradient is to be computed. This
  function must return a scalar value.
- `x::CUDA.CuVecOrMat`: The point at which the gradient is to be computed. Can
  be a vector or a matrix. If a matrix, each column represents a point where the
  function f is to be evaluated and the derivative computed.

# Optional Keyword Arguments
- `fdtype::Symbol=:central`: The finite difference type. It can be either
  `:forward` or `:central`. Defaults to `:central`.

# Returns
- A vector or a matrix representing the gradient of `f` at `x`, depending on the
  input type of `x`.

# Description
This function computes the finite difference gradient of a function `f` at a
point `x` on GPUs. The gradient is a vector or a matrix where the `i`-th element
is the partial derivative of `f` with respect to the `i`-th element of `x`.

The partial derivatives are computed using the forward or central difference
formula, depending on the `fdtype` argument:

- Forward difference formula: ∂f/∂xᵢ ≈ [f(x + ε * eᵢ) - f(x)] / ε
- Central difference formula: ∂f/∂xᵢ ≈ [f(x + ε * eᵢ) - f(x - ε * eᵢ)] / 2ε

where ε is the step size and eᵢ is the `i`-th unit vector.

# Note
This method is designed to work with GPUs.
"""
function finite_difference_gradient(
    f::Function,
    x::CUDA.CuVecOrMat;
    fdtype::Symbol=:central,
)
    # Check that mode is either :forward or :central
    if !(fdtype in (:forward, :central))
        error("fdtype must be either :forward or :central")
    end # if

    # Check fdtype
    if fdtype == :forward
        # Define step size
        ε = √(eps(eltype(x)))
        # Generate unit vectors times step size for each element of x
        Δx = unit_vectors(x) .* ε
        # Compute the finite difference gradient for each element of x
        grad = (f.([x + δ for δ in Δx]) .- f(x)) ./ ε
    else
        # Define step size
        ε = ∛(eps(eltype(x)))
        # Generate unit vectors times step size for each element of x
        Δx = unit_vectors(x) .* ε
        # Compute the finite difference gradient for each element of x
        grad = (f.([x + δ for δ in Δx]) - f.([x - δ for δ in Δx])) ./ (2ε)
    end # if

    if typeof(x) <: AbstractVector
        return grad
    elseif typeof(x) <: AbstractMatrix
        return permutedims(reduce(hcat, grad), [2, 1])
    end # if
end # function

# ==============================================================================
# Define TaylorDiff gradient function
# ==============================================================================

@doc raw"""
    taylordiff_gradient(
        f::Function,
        x::AbstractVector
    )

Compute the gradient of a function `f` at a point `x` using Taylor series
differentiation.

# Arguments
- `f::Function`: The function for which the gradient is to be computed. This
  must be a scalar function.
- `x::AbstractVector`: The point at which the gradient is to be computed.

# Returns
- A vector representing the gradient of `f` at `x`.

# Description
This function computes the gradient of a function `f` at a point `x` using
Taylor series differentiation. The gradient is a vector where the `i`-th element
is the partial derivative of `f` with respect to the `i`-th element of `x`.

The partial derivatives are computed using the TaylorDiff.derivative function.
"""
function taylordiff_gradient(
    f::Function,
    x::AbstractVector;
)
    # Compute the gradient for each element of x
    grad = TaylorDiff.derivative.(Ref(f), Ref(x), unit_vectors(x), Ref(1))

    return grad
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    taylordiff_gradient(
        f::Function,
        x::AbstractMatrix
    )

Compute the gradient of a function `f` at each column of `x` using Taylor series
differentiation.

# Arguments
- `f::Function`: The function for which the gradient is to be computed. This
  must be a scalar function. However, when applied to a matrix, the function
  should return a vector, where each element is the scalar output of the
  function applied to each column of the matrix.
- `x::AbstractMatrix`: A matrix where each column represents a point at which
  the gradient is to be computed.

# Returns
- A matrix where each column represents the gradient of `f` at the corresponding
  column of `x`.

# Description
This function computes the gradient of a function `f` at each column of `x`
using Taylor series differentiation. The gradient is a matrix where the `i`-th
column is the gradient of `f` with respect to the `i`-th column of `x`.

The gradients are computed using the TaylorDiff.derivative function, with each
column of `x` treated as a separate point. The result is then moved to the GPU
using `Flux.gpu`.
"""
function taylordiff_gradient(
    f::Function,
    x::AbstractMatrix;
)
    # Compute the gradient for each column of x
    grad = permutedims(
        reduce(
            hcat,
            TaylorDiff.derivative.(
                Ref(f), Ref(x), unit_vectors(x[:, 1]), Ref(1)
            )
        ),
        [2, 1]
    )

    return grad
end # function

# function taylordiff_gradient(
#     f::Function,
#     x::CUDA.CuMatrix;
# )
#     # Compute the gradient for each column of x
#     grad = permutedims(
#         reduce(
#             hcat,
#             TaylorDiff.derivative.(
#                 [(f, x, u, 1) for u in unit_vectors(x[:, 1])]...
#             )
#         ),
#         [2, 1]
#     )
#     return grad
# end # function