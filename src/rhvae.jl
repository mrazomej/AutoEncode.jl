# Import FillArrays
using FillArrays: Fill

# Import ML libraries
import Flux
import Zygote

# Import basic math
import Distances
import LinearAlgebra
import Random
import StatsBase
import Distributions

# Import Abstract Types
using ..AutoEncode: AbstractVariationalAutoEncoder,
    AbstractVariationalEncoder, AbstractGaussianEncoder,
    AbstractGaussianLogEncoder,
    AbstractVariationalDecoder, AbstractGaussianDecoder,
    AbstractGaussianLogDecoder, AbstractGaussianLinearDecoder,
    Float32Array

# Import Concrete Encoder Types
using ..AutoEncode: JointLogEncoder

# Import Concrete Decoder Types
using ..AutoEncode: SimpleDecoder,
    JointLogDecoder, SplitLogDecoder,
    JointDecoder, SplitDecoder

# Import Concrete VAE type
using ..AutoEncode: VAE

# Import functions from other modules
using ..VAEs: reparameterize
using ..utils: vec_to_ltri
using ..HVAEs: decoder_loglikelihood, spherical_logprior,
    quadratic_tempering, null_tempering

## %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
#  Chadebec, C., Mantoux, C. & Allassonnière, S. Geometry-Aware Hamiltonian
#  Variational Auto-Encoder. Preprint at http://arxiv.org/abs/2010.11518 (2020).
## %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

# ==============================================================================
# Defining MetricChain to compute the Riemannian metric tensor in latent space
# ==============================================================================

@doc raw"""
    MetricChain <: AbstractMetricChain

A `MetricChain` is used to compute the Riemannian metric tensor in the latent
space of a Riemannian Hamiltonian Variational AutoEncoder (RHVAE).

# Fields
- `mlp::Flux.Chain`: A multi-layer perceptron (MLP) consisting of the hidden
  layers. The inputs are first run through this MLP.
- `diag::Flux.Dense`: A dense layer that computes the diagonal elements of a
  lower-triangular matrix. The output of the `mlp` is fed into this layer.
- `lower::Flux.Dense`: A dense layer that computes the off-diagonal elements of
  the lower-triangular matrix. The output of the `mlp` is also fed into this
  layer.

The outputs of `diag` and `lower` are used to construct a lower-triangular
matrix used to compute the Riemannian metric tensor in latent space.

# Example
```julia
mlp = Flux.Chain(Dense(10, 10, relu), Dense(10, 10, relu))
diag = Flux.Dense(10, 5)
lower = Flux.Dense(10, 15)
metric_chain = MetricChain(mlp, diag, lower)
```
"""
struct MetricChain
    mlp::Flux.Chain
    diag::Flux.Dense
    lower::Flux.Dense
end # struct

# Mark function as Flux.Functors.@functor so that Flux.jl allows for training
Flux.@functor MetricChain

# ------------------------------------------------------------------------------

@doc raw"""
    MetricChain(
        n_input::Int,
        n_latent::Int,
        metric_neurons::Vector{<:Int},
        metric_activation::Vector{<:Function},
        output_activation::Function;
        init::Function=Flux.glorot_uniform
    ) -> MetricChain

Construct a `MetricChain` for computing the Riemannian metric tensor in the
latent space.

# Arguments
- `n_input::Int`: The number of input features.
- `n_latent::Int`: The dimension of the latent space.
- `metric_neurons::Vector{<:Int}`: The number of neurons in each hidden layer of
  the MLP.
- `metric_activation::Vector{<:Function}`: The activation function for each
  hidden layer of the MLP.
- `output_activation::Function`: The activation function for the output layer.
- `init::Function`: The initialization function for the weights in the layers
  (default is `Flux.glorot_uniform`).

# Returns
- `MetricChain`: A `MetricChain` object that includes the MLP, and two dense
  layers for computing the elements of a lower-triangular matrix used to compute
  the Riemannian metric tensor in latent space.
"""
function MetricChain(
    n_input::Int,
    n_latent::Int,
    metric_neurons::Vector{<:Int},
    metric_activation::Vector{<:Function},
    output_activation::Function;
    init::Function=Flux.glorot_uniform
)
    # Check that the number of activation functions matches the number of layers
    if length(metric_activation) != length(metric_neurons)
        error("Each hidden layer needs exactly one activation function")
    end

    # Initialize list to store layers
    mlp_layers = []

    # Add first layer to list
    push!(
        mlp_layers,
        Flux.Dense(
            n_input => metric_neurons[1], metric_activation[1]; init=init
        )
    )

    # Loop over hidden layers
    for i = 2:length(metric_neurons)
        # Add layer to list
        push!(
            mlp_layers,
            Flux.Dense(
                metric_neurons[i-1] => metric_neurons[i], metric_activation[i]; init=init
            )
        )
    end # for

    # Create the MLP
    mlp = Flux.Chain(mlp_layers...)

    # Create the diag and lower layers. These layers have a number of neurons equal to the number of entries in a lower triangular matrix in the latent space.  
    diag = Flux.Dense(
        metric_neurons[end] => n_latent, output_activation; init=init
    )
    lower = Flux.Dense(
        metric_neurons[end] => n_latent * (n_latent - 1) ÷ 2,
        output_activation; init=init
    )

    return MetricChain(mlp, diag, lower)
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    (m::MetricChain)(x::AbstractArray{Float32}; matrix::Bool=false)

Perform a forward pass through the MetricChain.

# Arguments
- `x::AbstractArray{Float32}`: The input data to be processed. This should be a
  Float32 array.
- `matrix::Bool=false`: A boolean flag indicating whether to return the result
  as a lower triangular matrix (if `true`) or as a tuple of diagonal and lower
  off-diagonal elements (if `false`). Defaults to `false`.

# Returns
- If `matrix` is `true`, returns a lower triangular matrix constructed from the
  outputs of the `diag` and `lower` components of the MetricChain.
- If `matrix` is `false`, returns a `NamedTuple` with two elements: `diag`, the
  output of the `diag` component of the MetricChain, and `lower`, the output of
  the `lower` component of the MetricChain.

# Example
```julia
m = MetricChain(...)
x = rand(Float32, 100, 10)
m(x, matrix=true)  # Returns a lower triangular matrix
```
"""
function (m::MetricChain)(x::AbstractArray{Float32}; matrix::Bool=false)
    # Compute the output of the MLP
    mlp_out = m.mlp(x)

    # Compute the diagonal elements of the lower-triangular matrix
    diag_out = m.diag(mlp_out)

    # Compute the off-diagonal elements of the lower-triangular matrix
    lower_out = m.lower(mlp_out)

    # Check if matrix should be returned
    if matrix
        return vec_to_ltri(diag_out, lower_out)
    else
        return (diag=diag_out, lower=lower_out,)
    end # if
end # function

# ==============================================================================
# Riemannian Hamiltonian Variational AutoEncoder (RHVAE)
# ==============================================================================

@doc raw"""
    RHVAE{
        V<:VAE{<:AbstractVariationalEncoder,<:AbstractVariationalDecoder}
    } <: AbstractVariationalAutoEncoder

A Riemannian Hamiltonian Variational AutoEncoder (RHVAE) as described in
Chadebec, C., Mantoux, C. & Allassonnière, S. Geometry-Aware Hamiltonian
Variational Auto-Encoder. Preprint at http://arxiv.org/abs/2010.11518 (2020).

The RHVAE is a type of Variational AutoEncoder (VAE) that incorporates a
Riemannian metric in the latent space. This metric is computed by a
`MetricChain`, which is a struct that contains a multi-layer perceptron (MLP)
and two dense layers for computing the elements of a lower-triangular matrix.

The inverse metric is computed as follows:

G⁻¹(z) = ∑ᵢ₌₁ⁿ L_ψᵢ L_ψᵢᵀ exp(-‖z - cᵢ‖₂² / T²) + λIₗ

where L_ψᵢ is computed by the `MetricChain`, T is the temperature, λ is a
regularization factor, and each column of `centroids` are the cᵢ.

# Fields
- `vae::V`: The underlying VAE, where `V` is a subtype of `VAE` with an
  `AbstractVariationalEncoder` and an `AbstractVariationalDecoder`.
- `metric_chain::MetricChain`: The `MetricChain` that computes the Riemannian
  metric in the latent space.
- `centroids_data::Matrix{Float32}`: A matrix where each column represents a
  data point xᵢ from which the centroids cᵢ are computed by passing them through
  the encoder.
- `centroids_latent::Matrix{Float32}`: A matrix where each column represents a
  centroid cᵢ in the inverse metric computation.
- `M::Array{Float32, 3}`: A 3D array where each slice represents a L_ψᵢ L_ψᵢᵀ.
- `T::Float32`: The temperature parameter in the inverse metric computation.  
- `λ::Float32`: The regularization factor in the inverse metric computation.

# Constructor
The constructor for `RHVAE` takes the following arguments:
- `vae`: The underlying VAE.
- `metric_chain`: The `MetricChain` that computes the Riemannian metric.
- `centroids_data`: A matrix of data points used to compute the centroids.
- `T`: The temperature parameter.
- `λ`: The regularization factor.

It initializes `centroids_latent` as a zero matrix with the same number of
columns as `centroids_data` and number of rows equal to the dimensionality of
the latent space. `L` and `M` are initialized as 3D arrays of identity matrices,
with the third dimension equal to the number of columns in `centroids_data`.
"""
struct RHVAE{
    V<:VAE{<:AbstractVariationalEncoder,<:AbstractVariationalDecoder}
} <: AbstractVariationalAutoEncoder
    vae::V
    metric_chain::MetricChain
    centroids_data::Matrix{Float32}
    centroids_latent::Matrix{Float32}
    M::Array{Float32,3}
    T::Float32
    λ::Float32

    # Define default constructor
    function RHVAE(vae, metric_chain, centroids_data, T, λ)
        # Extract dimensionality of latent space
        ldim = size(vae.encoder.µ.weight, 1)

        # Initialize centroids_latent
        centroids_latent = zeros(
            Float32, ldim, size(centroids_data, 2)
        )

        # Initialize L
        L = reduce(
            (x, y) -> cat(x, y, dims=3),
            [
                Matrix{Float32}(LinearAlgebra.I(ldim))
                for _ in axes(centroids_data, 2)
            ]
        )

        # Initialize M
        M = L

        # Initialize RHVAE
        new{typeof(vae)}(
            vae, metric_chain, centroids_data, centroids_latent, M, T, λ,
        )
    end # function
end # struct

# Mark function as Flux.Functors.@functor so that Flux.jl allows for training
Flux.@functor RHVAE (vae, metric,)

# ==============================================================================
# Riemannian Metric computations
# ==============================================================================

@doc raw"""
    update_metric(
        rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractVariationalDecoder}}
    )

Compute the `centroids_latent` and `M` field of a `RHVAE` instance without
modifying the instance. This method is used when needing to backpropagate
through the RHVAE during training.

# Arguments
- `rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractVariationalDecoder}}`:
  The `RHVAE` instance to be updated.

# Returns
- NamedTuple with the following fields:
  - `centroids_latent::Matrix{Float32}`: A matrix where each column represents a
    centroid cᵢ in the inverse metric computation.
  - `M::Array{Float32, 3}`: A 3D array where each slice represents a L_ψᵢ L_ψᵢᵀ.
"""
function update_metric(
    rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractVariationalDecoder}}
)
    # Extract centroids_data
    centroids_data = rhvae.centroids_data
    # Run centroids_data through encoder and update centroids_latent
    centroids_latent = rhvae.vae.encoder(centroids_data).µ
    # Run centroids_data through metric_chain and update L
    L = reduce(
        (x, y) -> cat(x, y, dims=3),
        [
            rhvae.metric_chain(centroid, matrix=true)
            for centroid in eachcol(centroids_data)
        ]
    )
    # Update M by multiplying L by its transpose
    M = reduce(
        (x, y) -> cat(x, y, dims=3),
        [
            l * LinearAlgebra.transpose(l)
            for l in eachslice(L, dims=3)
        ]
    )

    return (centroids_latent=centroids_latent, M=M,)
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    update_metric!(
        rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractVariationalDecoder}},
        params::NamedTuple
    )

Update the `centroids_latent` and `M` fields of a `RHVAE` instance in place.

This function takes a `RHVAE` instance and a named tuple `params` containing the
new values for `centroids_latent` and `M`. It updates the `centroids_latent` and
`M` fields of the `RHVAE` instance with the provided values.

# Arguments
- `rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractVariationalDecoder}}`:
  The `RHVAE` instance to update.
- `params::NamedTuple`: A named tuple containing the new values for
  `centroids_latent` and `M`. Must have the keys `:centroids_latent` and `:M`.

# Returns
Nothing. The `RHVAE` instance is updated in place.
"""
function update_metric!(
    rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractVariationalDecoder}},
    params::NamedTuple
)
    # Check that params contains centroids_latent and M
    if !(:centroids_latent in keys(params) && :M in keys(params))
        error("params must contain centroids_latent and M")
    end # if

    # Update centroid_latent values in place
    rhvae.centroids_latent .= params.centroids_latent
    # Update M values in place
    rhvae.M .= params.M
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    update_metric!(
        rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractVariationalDecoder}}
    )

Update the `centroids_latent`, and `M` fields of a `RHVAE` instance in place.

This function takes a `RHVAE` instance as input and modifies its
`centroids_latent` and `M` fields. The `centroids_latent` field is updated by
running the `centroids_data` through the encoder of the underlying VAE and
extracting the mean (µ) of the resulting Gaussian distribution. The `M` field is
updated by running each column of the `centroids_data` through the
`metric_chain` and concatenating the results along the third dimension, then
each slice is updated by multiplying each slice of `L` by its transpose and
concating the results along the third dimension.

# Arguments
- `rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractVariationalDecoder}}`:
  The `RHVAE` instance to be updated.

# Notes
This function modifies the `RHVAE` instance in place, so it does not return
anything. The changes are made directly to the `centroids_latent`, `L`, and `M`
fields of the input `RHVAE` instance.
"""
function update_metric!(
    rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractVariationalDecoder}}
)
    # Extract centroids_data
    centroids_data = rhvae.centroids_data
    # Run centroids_data through encoder and update centroids_latent
    rhvae.centroids_latent .= rhvae.vae.encoder(centroids_data).µ
    # Run centroids_data through metric_chain and update L
    rhvae.L .= reduce(
        (x, y) -> cat(x, y, dims=3),
        [
            rhvae.metric_chain(centroid, matrix=true)
            for centroid in eachcol(centroids_data)
        ]
    )
    # Update M by multiplying L by its transpose
    rhvae.M .= reduce(
        (x, y) -> cat(x, y, dims=3),
        [
            L * LinearAlgebra.transpose(L)
            for L in eachslice(rhvae.L, dims=3)
        ]
    )
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    G_inv( 
        rhvae::RHVAE, 
        z::AbstractVector{Float32}
    )

Compute the inverse of the metric tensor G for a given point in the latent
space.

This function takes a `RHVAE` instance and a point `z` in the latent space, and
computes the inverse of the metric tensor G at that point. The computation is
based on the centroids and the temperature of the `RHVAE` instance, as well as a
regularization term. The inverse metric is computed as follows:

G⁻¹(z) = ∑ᵢ₌₁ⁿ L_ψᵢ L_ψᵢᵀ exp(-‖z - cᵢ‖₂² / T²) + λIₗ,

where L_ψᵢ is computed by the `MetricChain`, T is the temperature, λ is a
regularization factor, and each column of `centroids_latent` are the cᵢ.

# Arguments
- `rhvae::RHVAE`: The `RHVAE` instance.
- `z::AbstractVector{Float32}`: The point in the latent space.

# Returns
A matrix representing the inverse of the metric tensor G at the point `z`.

# Notes

The computation involves the squared Euclidean distance between z and each
centroid of the RHVAE instance, the exponential of the negative of these
distances divided by the square of the temperature, and a regularization term
proportional to the identity matrix. The result is a matrix of the same size as
the latent space.
"""
function G_inv(
    rhvae::RHVAE,
    z::AbstractVector{Float32},
)
    # Compute L_ψᵢ L_ψᵢᵀ exp(-‖z - cᵢ‖₂² / T²). Note: We do not use Distances.jl
    # because that performs in-place operations on the input, and this is not
    # compatible with Zygote.jl.
    LLexp = sum([
        rhvae.M[:, :, i] .*
        exp(-sum(abs2, (z - rhvae.centroids_latent[:, i]) ./ rhvae.T))
        for i in 1:size(rhvae.M, 3)
    ])
    # Return the sum of the LLexp slices plus the regularization term
    return LLexp + LinearAlgebra.diagm(rhvae.λ * ones(Float32, size(z, 1)))
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    G_inv_fast( 
        rhvae::RHVAE, 
        z::AbstractVector{Float32}
    )

Compute the inverse of the metric tensor G for a given point in the latent
space. These computations are performed in a fast manner, using mutating arrays,
thus are not differentiable. The speed difference might only be noticed for a
large number of centroids.

This function takes a `RHVAE` instance and a point `z` in the latent space, and
computes the inverse of the metric tensor G at that point. The computation is
based on the centroids and the temperature of the `RHVAE` instance, as well as a
regularization term. The inverse metric is computed as follows:

G⁻¹(z) = ∑ᵢ₌₁ⁿ L_ψᵢ L_ψᵢᵀ exp(-‖z - cᵢ‖₂² / T²) + λIₗ,

where L_ψᵢ is computed by the `MetricChain`, T is the temperature, λ is a
regularization factor, and each column of `centroids_latent` are the cᵢ.

# Arguments
- `rhvae::RHVAE`: The `RHVAE` instance.
- `z::AbstractVector{Float32}`: The point in the latent space.

# Returns
A matrix representing the inverse of the metric tensor G at the point `z`.

# Notes

The computation involves the squared Euclidean distance between z and each
centroid of the RHVAE instance, the exponential of the negative of these
distances divided by the square of the temperature, and a regularization term
proportional to the identity matrix. The result is a matrix of the same size as
the latent space.
"""
function G_inv_fast(
    rhvae::RHVAE,
    z::AbstractVector{Float32},
)
    # Compute Squared Euclidean distance between z and each centroid
    distances = Distances.colwise(
        Distances.SqEuclidean(), z, rhvae.centroids_latent
    )

    # Compute L_ψᵢ L_ψᵢᵀ exp(-‖z - cᵢ‖₂² / T²). Note: The reshape is necessary
    # to broadcast the elemnt-wise product with each slice of M.
    LLexp = rhvae.M .* reshape(exp.(-distances ./ rhvae.T^2), 1, 1, :)

    # Return the sum of the LLexp slices plus the regularization term
    return dropdims(sum(LLexp, dims=3); dims=3) +
           rhvae.λ * LinearAlgebra.I(size(z, 1))
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    G_inv_fast(
        rhvae::RHVAE,
        z::AbstractMatrix{Float32},
    )

Compute the inverse of the metric tensor G for a given set of points in the
latent space.

This function takes a `RHVAE` instance and a matrix `z` where each column
represents a point in the latent space, and computes the inverse of the metric
tensor G at each point. The computation is based on the centroids and the
temperature of the `RHVAE` instance, as well as a regularization term. The
inverse metric is computed as follows:

G⁻¹(z) = ∑ᵢ₌₁ⁿ L_ψᵢ L_ψᵢᵀ exp(-‖z - cᵢ‖₂² / T²) + λIₗ,

where L_ψᵢ is computed by the `MetricChain`, T is the temperature, λ is a
regularization factor, and each column of `centroids_latent` are the cᵢ.

# Arguments
- `rhvae::RHVAE`: The `RHVAE` instance.
- `z::AbstractMatrix{Float32}`: The matrix where each column represents a point
  in the latent space.

# Returns
A 3D array where each slice represents the inverse of the metric tensor G at
the corresponding point `z`.

# Notes

The computation involves the squared Euclidean distance between each column of
`z` and each centroid of the RHVAE instance, the exponential of the negative of
these distances divided by the square of the temperature, and a regularization
term proportional to the identity matrix. The result is a 4D array where each 3D
array is of the same size as the latent space.
"""
function G_inv_fast(
    rhvae::RHVAE,
    z::AbstractMatrix{Float32},
)
    # Compute Squared Euclidean distance between z and each centroid. Note: we
    # broadcast Distances.colwise over each column of z.
    distances = reduce(
        hcat,
        Distances.colwise.(
            Ref(Distances.SqEuclidean()),
            eachcol(z),
            Ref(rhvae.centroids_latent)
        )
    )

    # Compute L_ψᵢ L_ψᵢᵀ exp(-‖z - cᵢ‖₂² / T²). Note: The reshape is necessary
    # to broadcast the elemnt-wise product with each slice of M. The reduce in
    # combination with cat is used to append the resulting 3D arrays along a 4th
    # dimension.
    LLexp = reduce(
        (x, y) -> cat(x, y, dims=4),
        [
            rhvae.M .* reshape(exp.(-d ./ rhvae.T^2), 1, 1, :)
            for d in eachcol(distances)
        ]
    )

    # Return the sum of the LLexp slices plus the regularization term
    return dropdims(sum(LLexp, dims=3); dims=3) .+
           rhvae.λ * LinearAlgebra.I(size(z, 1))
end # function

## %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Generalized Hamiltonian Dynamics
## %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

# ==============================================================================
# Define Zygote.@adjoint for FillArrays.fill
# ==============================================================================

# Note: This is needed because the specific type of FillArrays.fill does not
# have a Zygote.@adjoint function defined. This causes an error when trying to
# backpropagate through the RHVAE.

# Define the Zygote.@adjoint function for the FillArrays.fill method.
# The function takes a matrix `x` of type Float32 and a size `sz` as input.
Zygote.@adjoint function (::Type{T})(x::Matrix{Float32}, sz) where {T<:Fill}
    # Define the backpropagation function for the adjoint.
    # The function takes a gradient `Δ` as input and returns the sum of the gradient and `nothing`.
    back(Δ::AbstractArray) = (sum(Δ), nothing)
    # Define the backpropagation function for the adjoint.
    # The function takes a gradient `Δ` as input and returns the value of `Δ` and `nothing`.
    back(Δ::NamedTuple) = (Δ.value, nothing)
    # Return the result of the FillArrays.fill method and the backpropagation function.
    return Fill(x, sz), back
end # @adjoint

# ==============================================================================
# Functions to compute Riemannian log-prior
# ==============================================================================

@doc raw"""
    riemannian_logprior(
        rhvae::RHVAE,
        z::AbstractVector{Float32},
        ρ::AbstractVector{Float32};
        G_inv::Function=G_inv,
    )

Compute the log-prior of a Gaussian distribution with a covariance matrix given
by the Riemannian metric.

# Arguments
- `rhvae::RHVAE`: The Relaxed Hamiltonian Variational Autoencoder (RHVAE) model.
- `z::AbstractVector{Float32}`: The latent variable vector.
- `ρ::AbstractVector{Float32}`: The momentum vector.

# Optional Keyword Arguments
- `G_inv::Function=G_inv`: The function to compute the inverse of the Riemannian
  metric tensor. This function should take two arguments: the RHVAE model and
  the latent variable vector, and return the inverse of the Riemannian metric
  tensor.

# Returns
The log-prior of the Gaussian distribution.

# Description
This function computes the log-prior of a Gaussian distribution with a
covariance matrix given by the Riemannian metric. It first computes the inverse
of the Riemannian metric tensor using the provided `G_inv` function, then
computes the log determinant of the metric tensor, and finally computes and
returns the log-prior.

# Notes
Ensure that the dimensions of `z` match the dimensions of the latent space of
the RHVAE model.
"""
function riemannian_logprior(
    rhvae::RHVAE,
    z::AbstractVector{Float32},
    ρ::AbstractVector{Float32};
    G_inv::Function=G_inv,
)
    # Compute the inverse metric tensor
    G⁻¹ = G_inv(rhvae, z)

    # Compute the log determinant of the metric tensor
    logdetG = -LinearAlgebra.logdet(G⁻¹)

    # Return the log-prior
    return 0.5f0 * (length(z) * log(2.0f0π) + logdetG) +
           0.5f0 * LinearAlgebra.dot(ρ, G⁻¹ * ρ)
end # function

# ==============================================================================
# Hamiltonian and gradient computations
# ==============================================================================

@doc raw"""
    hamiltonian(
        rhvae::RHVAE,
        x::AbstractVector{T},
        z::AbstractVector{T},
        ρ::AbstractVector{T};
        decoder_loglikelihood::Function=decoder_loglikelihood,
        position_logprior::Function=spherical_logprior,
        G_inv::Function=G_inv,
    ) where {T<:Float32}

Compute the Hamiltonian for a given point in the latent space and a given
momentum.

This function takes a `RHVAE` instance, a point `x` in the data space, a point
`z` in the latent space, and a momentum `ρ`, and computes the Hamiltonian. The
computation is based on the log-likelihood of the decoder, the log-prior of the
latent space, and the inverse of the metric tensor G at the point `z`.

The Hamiltonian is computed as follows:

Hₓ(z, ρ) = Uₓ(z) + 0.5 * log((2π)ᴰ det G(z)) + 0.5 * ρᵀ G(z)⁻¹ ρ,

where Uₓ(z) is the potential energy, computed as the negative sum of the
log-likelihood and the log-prior, D is the dimension of the latent space, and
G(z) is the metric tensor at the point `z`.

# Arguments
- `rhvae::RHVAE`: The `RHVAE` instance.
- `x::AbstractVector{T}`: The point in the data space.
- `z::AbstractVector{T}`: The point in the latent space.
- `ρ::AbstractVector{T}`: The momentum.
- `decoder_loglikelihood::Function`: The function to compute the log-likelihood
  of the decoder. Default is `decoder_loglikelihood`. This function must take as
  input the decoder, the point `x` in the data space, and the point `z` in the
  latent space.
- `position_logprior::Function`: The function to compute the log-prior of the
  latent space position. Default is `spherical_logprior`. This function must
  take as input the point `z` in the latent space.
- `momentum_logprior::Function`: The function to compute the log-prior of the
  latent space momentum. Default is `riemannian_logprior`. This function must
  take as input the RHVAE model, the point `z` in the latent space, and the
  momentum `ρ`. As an optional keyword argument, it can take a function `G_inv`.
- `G_inv::Function=G_inv`: The function to compute the inverse of the Riemannian
  metric tensor. This function should take two arguments: the RHVAE model and
  the latent variable vector, and return the inverse of the Riemannian metric
  tensor.


# Returns
A scalar representing the Hamiltonian at the point `z` with the momentum `ρ`.
"""
function hamiltonian(
    rhvae::RHVAE,
    x::AbstractVector{T},
    z::AbstractVector{T},
    ρ::AbstractVector{T};
    decoder_loglikelihood::Function=decoder_loglikelihood,
    position_logprior::Function=spherical_logprior,
    momentum_logprior::Function=riemannian_logprior,
    G_inv::Function=G_inv,
) where {T<:Float32}
    # 1. Potntial energy U(z|x)

    # Compute log-likelihood
    loglikelihood = decoder_loglikelihood(rhvae.vae.decoder, x, z)

    # Compute log-prior
    z_logprior = position_logprior(z)

    # Define potential energy
    U = -loglikelihood - z_logprior

    # 2. Kinetic energy K(ρ)
    κ = momentum_logprior(rhvae, z, ρ; G_inv=G_inv)

    # Return Hamiltonian
    return U + κ
end # function

# ------------------------------------------------------------------------------


@doc raw"""
    ∇hamiltonian(
        rhvae::RHVAE,
        x::AbstractVector{T},
        z::AbstractVector{T},
        ρ::AbstractVector{T},
        var::Symbol;
        decoder_loglikelihood::Function=decoder_loglikelihood,
        position_logprior::Function=spherical_logprior,
        G_inv::Function=G_inv,
    ) where {T<:Float32}

Compute the gradient of the Hamiltonian with respect to a given variable.

This function takes a `RHVAE` instance, a point `x` in the data space, a point
`z` in the latent space, a momentum `ρ`, and a variable `var` (:z or :ρ), and
computes the gradient of the Hamiltonian with respect to `var` using `Zygote.jl`
AutoDiff. The computation is based on the log-likelihood of the decoder, the
log-prior of the latent space, and the inverse of the metric tensor G at the
point `z`.

The Hamiltonian is computed as follows:

Hₓ(z, ρ) = Uₓ(z) + 0.5 * log((2π)ᴰ det G(z)) + 0.5 * ρᵀ G(z)⁻¹ ρ,

where Uₓ(z) is the potential energy, computed as the negative sum of the
log-likelihood and the log-prior, D is the dimension of the latent space, and
G(z) is the metric tensor at the point `z`.

# Arguments
- `rhvae::RHVAE`: The `RHVAE` instance.
- `x::AbstractVector{T}`: The point in the data space.
- `z::AbstractVector{T}`: The point in the latent space.
- `ρ::AbstractVector{T}`: The momentum.
- `var::Symbol`: The variable with respect to which the gradient is computed.
  Must be :z or :ρ.
- `decoder_loglikelihood::Function`: The function to compute the log-likelihood
  of the decoder. Default is `decoder_loglikelihood`. This function must take as
  input the decoder, the point `x` in the data space, and the point `z` in the
  latent space.
- `position_logprior::Function`: The function to compute the log-prior of the
  latent space position. Default is `spherical_logprior`. This function must
  take as input the point `z` in the latent space.
- `momentum_logprior::Function`: The function to compute the log-prior of the
  latent space momentum. Default is `riemannian_logprior`. This function must
  take as input the RHVAE model, the point `z` in the latent space, and the
  momentum `ρ`. As an optional keyword argument, it can take a function `G_inv`.
- `G_inv::Function=G_inv`: The function to compute the inverse of the Riemannian
  metric tensor. This function should take two arguments: the RHVAE model and
  the latent variable vector, and return the inverse of the Riemannian metric
  tensor.

# Returns
A vector representing the gradient of the Hamiltonian at the point `(z, ρ)` with
respect to variable `var`.
"""
function ∇hamiltonian(
    rhvae::RHVAE,
    x::AbstractVector{T},
    z::AbstractVector{T},
    ρ::AbstractVector{T},
    var::Symbol;
    decoder_loglikelihood::Function=decoder_loglikelihood,
    position_logprior::Function=spherical_logprior,
    momentum_logprior::Function=riemannian_logprior,
    G_inv::Function=G_inv,
) where {T<:Float32}
    # Check that var is a valid variable
    if var ∉ (:z, :ρ)
        error("var must be :z or :ρ")
    end # if
    # Define function to compute Hamiltonian.
    function H(z::AbstractVector{T}, ρ::AbstractVector{T})
        # 1. Potential energy U(z|x)
        # Compute log-likelihood
        loglikelihood = decoder_loglikelihood(rhvae.vae.decoder, x, z)
        # Compute log-prior
        z_logprior = position_logprior(z)
        # Define potential energy
        U = -loglikelihood - z_logprior

        # 2. Kinetic energy K(ρ)
        κ = momentum_logprior(rhvae, z, ρ; G_inv=G_inv)

        # Return Hamiltonian
        return U + κ
    end # function

    # Compute gradient with respect to var
    if var == :z
        return Zygote.gradient(z -> H(z, ρ), z)[1]
    elseif var == :ρ
        return Zygote.gradient(ρ -> H(z, ρ), ρ)[1]
    end # if
end # function

# ==============================================================================
# Generalized Leapfrog Integrator
# ==============================================================================

@doc raw"""
    _leapfrog_ρ_step(
        rhvae::RHVAE,
        x::AbstractVector{T},
        z::AbstractVector{T},
        ρ::AbstractVector{T},
        ϵ::Union{T,<:AbstractVector{T}};
        steps::Int=1,
        ∇H::Function=∇hamiltonian,
        ∇H_kwargs::Union{NamedTuple,Dict}=(
            decoder_loglikelihood=decoder_loglikelihood,
            position_logprior=spherical_logprior,
            momentum_logprior=riemannian_logprior,
            G_inv=G_inv,
        ),
    ) where {T<:Float32}

Perform the first step of the generalized leapfrog integrator for Hamiltonian
dynamics, defined as

ρ(t + ϵ/2) = ρ(t) - 0.5 * ϵ * ∇z_H(z(t), ρ(t + ϵ/2)).

This function is part of the generalized leapfrog integrator used in Hamiltonian
dynamics. Unlike the standard leapfrog integrator, the generalized leapfrog
integrator is implicit, which means it requires the use of fixed-point
iterations to be solved.

The function takes a `RHVAE` instance, a point `x` in the data space, a point
`z` in the latent space, a momentum `ρ`, a step size `ϵ`, and optionally the
number of fixed-point iterations to perform (`steps`), a function to compute the
gradient of the Hamiltonian (`∇H`), and a set of keyword arguments for `∇H`
(`∇H_kwargs`).

The function performs the following update for `steps` times:

ρ̃ = ρ̃ - 0.5 * ϵ * ∇H(rhvae, x, z, ρ̃, :z; ∇H_kwargs...)

where `∇H` is the gradient of the Hamiltonian with respect to the position
variables `z`. The result is returned as ρ̃.

# Arguments
- `rhvae::RHVAE`: The `RHVAE` instance.
- `x::AbstractVector{T}`: The point in the data space.
- `z::AbstractVector{T}`: The point in the latent space.
- `ρ::AbstractVector{T}`: The momentum.
- `ϵ::Union{T,<:AbstractVector{T}}`: The step size.

# Optional Keyword Arguments
- `steps::Int=3`: The number of fixed-point iterations to perform. Default is 1.
  Typically, 3 iterations are sufficient.
- `∇H::Function=∇hamiltonian`: The function to compute the gradient of the
  Hamiltonian. Default is `∇hamiltonian`.
- `∇H_kwargs::Union{NamedTuple,Dict}`: The keyword arguments for `∇H`. Default
  is a tuple with `decoder_loglikelihood`, `position_logprior`,
  `momentum_logprior`, and `G_inv`.

# Returns
A vector representing the updated momentum after performing the first step of
the generalized leapfrog integrator.
"""
function _leapfrog_ρ_step(
    rhvae::RHVAE,
    x::AbstractVector{T},
    z::AbstractVector{T},
    ρ::AbstractVector{T},
    ϵ::Union{T,<:AbstractVector{T}};
    steps::Int=3,
    ∇H::Function=∇hamiltonian,
    ∇H_kwargs::Union{NamedTuple,Dict}=(
        decoder_loglikelihood=decoder_loglikelihood,
        position_logprior=spherical_logprior,
        momentum_logprior=riemannian_logprior,
        G_inv=G_inv,
    ),
) where {T<:Float32}
    # Copy ρ to iterate over it
    ρ̃ = deepcopy(ρ)

    # Loop over steps
    for _ in 1:steps
        # Update momentum variable into a new temporary variable
        ρ̃_ = ρ̃ - (0.5f0 * ϵ) .* ∇H(rhvae, x, z, ρ̃, :z; ∇H_kwargs...)
        # Update momentum variable for next cycle
        ρ̃ = ρ̃_
    end # for

    return ρ̃
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    _leapfrog_z_step(
            rhvae::RHVAE,
            x::AbstractVector{T},
            z::AbstractVector{T},
            ρ::AbstractVector{T},
            ϵ::Union{T,<:AbstractVector{T}};
            steps::Int=3,
            ∇H::Function=∇hamiltonian,
            ∇H_kwargs::Union{NamedTuple,Dict}=(
                    decoder_loglikelihood=decoder_loglikelihood,
                    position_logprior=spherical_logprior,
                    momentum_logprior=riemannian_logprior,
                    G_inv=G_inv,
            ),
    ) where {T<:Float32}

Perform the second step of the generalized leapfrog integrator for Hamiltonian
dynamics, defined as

z(t + ϵ) = z(t) + 0.5 * ϵ * [∇ρ_H(z(t), ρ(t+ϵ/2)) + ∇ρ_H(z(t + ϵ), ρ(t+ϵ/2))].

This function is part of the generalized leapfrog integrator used in Hamiltonian
dynamics. Unlike the standard leapfrog integrator, the generalized leapfrog
integrator is implicit, which means it requires the use of fixed-point
iterations to be solved.

The function takes a `RHVAE` instance, a point `x` in the data space, a point
`z` in the latent space, a momentum `ρ`, a step size `ϵ`, and optionally the
number of fixed-point iterations to perform (`steps`), a function to compute the
gradient of the Hamiltonian (`∇H`), and a set of keyword arguments for `∇H`
(`∇H_kwargs`).

The function performs the following update for `steps` times:

z̄ = z̄ + 0.5 * ϵ * ( ∇H(rhvae, x, z̄, ρ, :ρ; ∇H_kwargs...) + ∇H(rhvae, x, z, ρ,
    :ρ; ∇H_kwargs...) )

where `∇H` is the gradient of the Hamiltonian with respect to the momentum
variables `ρ`. The result is returned as z̄.

# Arguments
- `rhvae::RHVAE`: The `RHVAE` instance.
- `x::AbstractVector{T}`: The point in the data space.
- `z::AbstractVector{T}`: The point in the latent space.
- `ρ::AbstractVector{T}`: The momentum.
- `ϵ::Union{T,<:AbstractVector{T}}`: The step size.

# Optional Keyword Arguments
- `steps::Int=3`: The number of fixed-point iterations to perform. Default is 3.
  Typically, 3 iterations are sufficient.
- `∇H::Function=∇hamiltonian`: The function to compute the gradient of the
  Hamiltonian. Default is `∇hamiltonian`.
- `∇H_kwargs::Union{NamedTuple,Dict}`: The keyword arguments for `∇H`. Default
  is a tuple with `decoder_loglikelihood`, `position_logprior`,
  `momentum_logprior`, and `G_inv`.

# Returns
A vector representing the updated position after performing the second step of
the generalized leapfrog integrator.
"""
function _leapfrog_z_step(
    rhvae::RHVAE,
    x::AbstractVector{T},
    z::AbstractVector{T},
    ρ::AbstractVector{T},
    ϵ::Union{T,<:AbstractVector{T}};
    steps::Int=3,
    ∇H::Function=∇hamiltonian,
    ∇H_kwargs::Union{NamedTuple,Dict}=(
        decoder_loglikelihood=decoder_loglikelihood,
        position_logprior=spherical_logprior,
        momentum_logprior=riemannian_logprior,
        G_inv=G_inv,
    ),
) where {T<:Float32}
    # Compute Hamiltonian gradient for initial point not to repeat it at each
    # iteration 
    ∇H_ = ∇H(rhvae, x, z, ρ, :ρ; ∇H_kwargs...)

    # Copy z to iterate over it
    z̄ = deepcopy(z)

    # Loop over steps
    for _ in 1:steps
        # Update position variable into a new temporary variable
        z̄_ = z̄ + (0.5f0 * ϵ) .* (∇H_ + ∇H(rhvae, x, z̄, ρ, :ρ; ∇H_kwargs...))
        # Update position variable for next cycle
        z̄ = z̄_
    end # for

    return z̄
end # function

# ------------------------------------------------------------------------------

@doc raw"""
        general_leapfrog_step(
                rhvae::RHVAE,
                x::AbstractVector{T},
                z::AbstractVector{T},
                ρ::AbstractVector{T},
                ϵ::Union{T,<:AbstractVector{T}};
                steps::Int=3,
                ∇H::Function=∇hamiltonian,
                ∇H_kwargs::Union{NamedTuple,Dict}=(
                        decoder_loglikelihood=decoder_loglikelihood,
                        position_logprior=spherical_logprior,
                        momentum_logprior=riemannian_logprior,
                        G_inv=G_inv,
                ),
        ) where {T<:Float32}

Perform a full step of the generalized leapfrog integrator for Hamiltonian
dynamics.

The leapfrog integrator is a numerical integration scheme used to simulate
Hamiltonian dynamics. It consists of three steps:

1. Half update of the momentum variable: ρ(t + ϵ/2) = ρ(t) - 0.5 * ϵ *
        ∇z_H(z(t), ρ(t + ϵ/2)).
2. Full update of the position variable: z(t + ϵ) = z(t) + 0.5 * ϵ * [∇ρ_H(z(t),
        ρ(t+ϵ/2)) + ∇ρ_H(z(t + ϵ), ρ(t+ϵ/2))].
3. Half update of the momentum variable: ρ(t + ϵ) = ρ(t + ϵ/2) - 0.5 * ϵ *
        ∇z_H(z(t + ϵ), ρ(t + ϵ/2)).

This function performs these three steps in sequence, using the
`_leapfrog_ρ_step` and `_leapfrog_z_step` helper functions.

# Arguments
- `rhvae::RHVAE`: The `RHVAE` instance.
- `x::AbstractVector{T}`: The point in the data space.
- `z::AbstractVector{T}`: The point in the latent space.
- `ρ::AbstractVector{T}`: The momentum.
- `ϵ::Union{T,<:AbstractVector{T}}`: The step size.

# Optional Keyword Arguments
- `steps::Int=3`: The number of fixed-point iterations to perform. Default is 3.
    Typically, 3 iterations are sufficient.
- `∇H::Function=∇hamiltonian`: The function to compute the gradient of the
    Hamiltonian. Default is `∇hamiltonian`.
- `∇H_kwargs::Union{NamedTuple,Dict}`: The keyword arguments for `∇H`. Default
    is a tuple with `decoder_loglikelihood`, `position_logprior`,
    `momentum_logprior` and `G_inv`.

# Returns
A tuple `(z̄, ρ̄)` representing the updated position and momentum after
performing the full leapfrog step.
"""
function general_leapfrog_step(
    rhvae::RHVAE,
    x::AbstractVector{T},
    z::AbstractVector{T},
    ρ::AbstractVector{T},
    ϵ::Union{T,<:AbstractVector{T}};
    steps::Int=3,
    ∇H::Function=∇hamiltonian,
    ∇H_kwargs::Union{NamedTuple,Dict}=(
        decoder_loglikelihood=decoder_loglikelihood,
        position_logprior=spherical_logprior,
        momentum_logprior=riemannian_logprior,
        G_inv=G_inv,
    ),
) where {T<:Float32}
    # Update momentum variable with half step
    ρ̃ = _leapfrog_ρ_step(
        rhvae, x, z, ρ, ϵ; steps=steps, ∇H=∇H, ∇H_kwargs=∇H_kwargs,
    )

    # Update position variable with full step
    z̄ = _leapfrog_z_step(
        rhvae, x, z, ρ̃, ϵ; steps=steps, ∇H=∇H, ∇H_kwargs=∇H_kwargs,
    )

    # Update momentum variable with half step
    ρ̄ = _leapfrog_ρ_step(
        rhvae, x, z̄, ρ̃, ϵ; steps=steps, ∇H=∇H, ∇H_kwargs=∇H_kwargs,
    )

    return z̄, ρ̄
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    general_leapfrog_step(
        rhvae::RHVAE,
        x::AbstractMatrix{T},
        z::AbstractMatrix{T},
        ρ::AbstractMatrix{T},
        ϵ::Union{T,<:AbstractVector{T}};
        steps::Int=3,
        ∇H::Function=∇hamiltonian,
        ∇H_kwargs::Union{NamedTuple,Dict}=(
            decoder_loglikelihood=decoder_loglikelihood,
            position_logprior=spherical_logprior,
            momentum_logprior=riemannian_logprior,
            G_inv=G_inv,
        ),
    ) where {T<:Float32}

Perform a full step of the generalized leapfrog integrator for Hamiltonian
dynamics on each column of the input matrices.

The leapfrog integrator is a numerical integration scheme used to simulate
Hamiltonian dynamics. It consists of three steps:

1. Half update of the momentum variable: ρ(t + ϵ/2) = ρ(t) - 0.5 * ϵ *
    ∇z_H(z(t), ρ(t + ϵ/2)).
2. Full update of the position variable: z(t + ϵ) = z(t) + 0.5 * ϵ * [∇ρ_H(z(t),
    ρ(t+ϵ/2)) + ∇ρ_H(z(t + ϵ), ρ(t+ϵ/2))].
3. Half update of the momentum variable: ρ(t + ϵ) = ρ(t + ϵ/2) - 0.5 * ϵ *
    ∇z_H(z(t + ϵ), ρ(t + ϵ/2)).

This function performs these three steps in sequence for each column of the
input matrices, using the `_leapfrog_ρ_step` and `_leapfrog_z_step` helper
functions.

# Arguments
- `rhvae::RHVAE`: The `RHVAE` instance.
- `x::AbstractMatrix{T}`: The points in the data space. Each column represents a
  point.
- `z::AbstractMatrix{T}`: The points in the latent space. Each column represents
  a point.
- `ρ::AbstractMatrix{T}`: The momenta. Each column represents a momentum.
- `ϵ::Union{T,<:AbstractVector{T}}`: The step size.

# Optional Keyword Arguments
- `steps::Int=3`: The number of fixed-point iterations to perform. Default is 3.
    Typically, 3 iterations are sufficient.
- `∇H::Function=∇hamiltonian`: The function to compute the gradient of the
    Hamiltonian. Default is `∇hamiltonian`.
- `∇H_kwargs::Union{NamedTuple,Dict}`: The keyword arguments for `∇H`. Default
    is a tuple with `decoder_loglikelihood`, `position_logprior`,
    `momentum_logprior`, and `G_inv`.

# Returns
Two matrices `(z̄, ρ̄)` representing the updated positions and momenta after
performing the full leapfrog step on each column of the input matrices.
"""
function general_leapfrog_step(
    rhvae::RHVAE,
    x::AbstractMatrix{T},
    z::AbstractMatrix{T},
    ρ::AbstractMatrix{T},
    ϵ::Union{T,<:AbstractVector{T}};
    steps::Int=3,
    ∇H::Function=∇hamiltonian,
    ∇H_kwargs::Union{NamedTuple,Dict}=(
        decoder_loglikelihood=decoder_loglikelihood,
        position_logprior=spherical_logprior,
        momentum_logprior=riemannian_logprior,
        G_inv=G_inv,
    ),
) where {T<:Float32}
    # Apply general_leapfrog_step to each column and collect the results
    results = [
        general_leapfrog_step(
            rhvae, x[:, i], z[:, i], ρ[:, i], ϵ;
            steps=steps, ∇H=∇H, ∇H_kwargs=∇H_kwargs
        )
        for i in axes(z, 2)
    ]

    # Split the results into separate matrices for z̄ and ρ̄
    z̄ = reduce(hcat, [result[1] for result in results])
    ρ̄ = reduce(hcat, [result[2] for result in results])

    return z̄, ρ̄
end # function

# ==============================================================================
# Combining Leapfrog and Tempering Steps
# ==============================================================================

@doc raw"""
        general_leapfrog_tempering_step(
                rhvae::RHVAE,
                x::AbstractVecOrMat{T},
                zₒ::AbstractVecOrMat{T},
                K::Int=3,
                ϵ::Union{T,<:AbstractVector{T}}=0.001f0,
                βₒ::T=0.3f0,
                steps::Int=3,
                ∇H::Function=∇hamiltonian,
                ∇H_kwargs::Union{NamedTuple,Dict}=(
                        decoder_loglikelihood=decoder_loglikelihood,
                        position_logprior=spherical_logprior,
                        momentum_logprior=riemannian_logprior,
                        G_inv=G_inv,
                ),
                tempering_schedule::Function=quadratic_tempering,
        ) where {T<:Float32}

Combines the leapfrog and tempering steps into a single function for the Relaxed
Hamiltonian Variational Autoencoder (RHVAE).

# Arguments
- `rhvae::RHVAE`: The Relaxed Hamiltonian Variational Autoencoder model.
- `x::AbstractVecOrMat{T}`: The data to be processed. Can be a vector or a
  matrix.
- `zₒ::AbstractVecOrMat{T}`: The initial latent variable. Can be a vector or a
  matrix.  

# Optional Keyword Arguments
- `K::Int`: The number of leapfrog steps to perform in the Hamiltonian Monte
  Carlo (HMC) algorithm. Default is 3.
- `ϵ::Union{T,<:AbstractVector{T}}`: The step size for the leapfrog steps in the
  HMC algorithm. This can be a scalar or an array. Default is 0.001f0.  
- `βₒ::T`: The initial inverse temperature for the tempering schedule. Default
  is 0.3f0.
- `steps::Int`: The number of fixed-point iterations to perform. Default is 3.
- `∇H::Function`: The function to compute the gradient of the Hamiltonian.
  Default is `∇hamiltonian`.
- `∇H_kwargs::Union{NamedTuple,Dict}`: Additional keyword arguments to be passed
  to the `∇H` function. Default is a NamedTuple with `decoder_loglikelihood`,
  `position_logprior`, `momentum_logprior`, and `G_inv`.  
- `tempering_schedule::Function`: The function to compute the inverse
  temperature at each step in the HMC algorithm. Defaults to
  `quadratic_tempering`. This function must take three arguments: First, `βₒ`,
  an initial inverse temperature, second, `k`, the current step in the tempering
  schedule, and third, `K`, the total number of steps in the tempering schedule.

# Returns
- A `NamedTuple` with the following keys:
    - `z_init`: The initial latent variable.
    - `ρ_init`: The initial momentum variable.
    - `z_final`: The final latent variable after `K` leapfrog steps.
    - `ρ_final`: The final momentum variable after `K` leapfrog steps.

# Description
The function first samples a random momentum variable `γₒ` from a standard
normal distribution and scales it by the inverse square root of the initial
inverse temperature `βₒ` to obtain the initial momentum variable `ρₒ`. Then, it
performs `K` leapfrog steps, each followed by a tempering step, to generate a
new sample from the latent space.

# Note
Ensure the input data `x` and the initial latent variable `zₒ` match the
expected input dimensionality for the RHVAE model. Both `x` and `zₒ` can be
either vectors or matrices.
"""
function general_leapfrog_tempering_step(
    rhvae::RHVAE,
    x::AbstractVector{T},
    zₒ::AbstractVector{T};
    K::Int=3,
    ϵ::Union{T,<:AbstractVector{T}}=0.001f0,
    βₒ::T=0.3f0,
    steps::Int=3,
    ∇H::Function=∇hamiltonian,
    ∇H_kwargs::Union{NamedTuple,Dict}=(
        decoder_loglikelihood=decoder_loglikelihood,
        position_logprior=spherical_logprior,
        momentum_logprior=riemannian_logprior,
        G_inv=G_inv,
    ),
    tempering_schedule::Function=quadratic_tempering,
) where {T<:Float32}
    # Extract latent-space dimensionality
    ldim = size(zₒ, 1)

    # Sample γₒ ~ N(0, I)
    if isa(zₒ, AbstractVector)
        γₒ = Random.rand(Distributions.MvNormal(zeros(T, ldim), ones(T, ldim)))
    else
        γₒ = Random.rand(
            Distributions.MvNormal(zeros(T, ldim), ones(T, ldim)), size(zₒ, 2)
        )
    end # if

    # Define ρₒ = γₒ / √βₒ
    ρₒ = γₒ ./ √(βₒ)

    # Define initial value of z and ρ before loop
    zₖ₋₁ = deepcopy(zₒ)
    ρₖ₋₁ = deepcopy(ρₒ)

    # Loop over K steps
    for k = 1:K
        # 1) Leapfrog step
        zₖ, ρₖ = general_leapfrog_step(
            rhvae, x, zₖ₋₁, ρₖ₋₁, ϵ;
            steps=steps, ∇H=∇H, ∇H_kwargs=∇H_kwargs,
        )

        # 2) Tempering step
        # Compute previous step's inverse temperature
        βₖ₋₁ = tempering_schedule(βₒ, k - 1, K)
        # Compute current step's inverse temperature
        βₖ = tempering_schedule(βₒ, k, K)

        # Update momentum variable with tempering Update zₖ₋₁, ρₖ₋₁ for next
        # iteration. The momentum variable is updated with tempering. Also, note
        # this is the last step as well, thus we return zₖ₋₁, ρₖ₋₁ as the final
        # points.
        zₖ₋₁ = zₖ
        ρₖ₋₁ = ρₖ .* √(βₖ₋₁ / βₖ)
    end # for

    return (
        z_init=zₒ,
        ρ_init=ρₒ,
        z_final=zₖ₋₁,
        ρ_final=ρₖ₋₁,
    )
end # function

# ==============================================================================
# Forward pass methods for RHVAE with Generalized Hamiltonian steps
# ==============================================================================

@doc raw"""
        (rhvae::RHVAE{VAE{JointLogEncoder,D}})(
                x::AbstractVecOrMat{T};
                K::Int=3,
                ϵ::Union{T,<:AbstractVector{T}}=0.001f0,
                βₒ::T=0.3f0,
                ∇H::Function=∇hamiltonian,
                ∇H_kwargs::Union{NamedTuple,Dict}=(
                        decoder_loglikelihood=decoder_loglikelihood,
                        position_logprior=spherical_logprior,
                        momentum_logprior=riemannian_logprior,
                        G_inv=G_inv,
                ),
                tempering_schedule::Function=quadratic_tempering,
                latent::Bool=false,
        ) where {D<:AbstractGaussianDecoder,T<:Float32}

Run the Relaxed Hamiltonian Variational Autoencoder (RHVAE) on the given input.

# Arguments
- `x::AbstractVecOrMat{T}`: The input to the RHVAE. If it is a vector, it
    represents a single data point. If it is a matrix, each column corresponds
    to a specific data point, and each row corresponds to a dimension of the
    input space.

# Optional Keyword Arguments
- `K::Int=3`: The number of leapfrog steps to perform in the Hamiltonian Monte
  Carlo (HMC) part of the RHVAE.
- `ϵ::Union{T,<:AbstractVector{T}}=0.001f0`: The step size for the leapfrog steps
  in the HMC part of the RHVAE. If it is a scalar, the same step size is used
  for all dimensions. If it is an array, each element corresponds to the step
  size for a specific dimension.
- `βₒ::T=0.3f0`: The initial inverse temperature for the tempering schedule.
- `∇H::Function=∇hamiltonian`: The function to compute the gradient of the
  Hamiltonian in the HMC part of the RHVAE.
- `∇H_kwargs::Union{NamedTuple,Dict}`: Additional keyword arguments to be passed
  to the `∇H` function. Default is a NamedTuple with `decoder_loglikelihood`,
  `position_logprior`, `momentum_logprior`, and `G_inv`.  
- `tempering_schedule::Function=quadratic_tempering`: The function to compute
  the tempering schedule in the RHVAE.
- `latent::Bool=false`: If `true`, the function returns a NamedTuple containing
  the outputs of the encoder and decoder, and the final state of the phase space
  after the leapfrog and tempering steps. If `false`, the function only returns
  the output of the decoder.

# Returns
If `latent=true`, the function returns a NamedTuple with the following fields:
- `encoder`: The outputs of the encoder.
- `decoder`: The output of the decoder.
- `phase_space`: The final state of the phase space after the leapfrog and
    tempering steps.

If `latent=false`, the function only returns the output of the decoder.

# Description
This function runs the RHVAE on the given input. It first passes the input
through the encoder to obtain the mean and log standard deviation of the latent
space. It then uses the reparameterization trick to sample from the latent
space. After that, it performs the leapfrog and tempering steps to refine the
sample from the latent space. Finally, it passes the refined sample through the
decoder to obtain the output.

# Notes
Ensure that the dimensions of `x` match the input dimensions of the RHVAE, and
that the dimensions of `ϵ` match the dimensions of the latent space.
"""
function (rhvae::RHVAE{VAE{JointLogEncoder,D}})(
    x::AbstractVecOrMat{T};
    K::Int=3,
    ϵ::Union{T,<:AbstractVector{T}}=0.001f0,
    βₒ::T=0.3f0,
    ∇H::Function=∇hamiltonian,
    ∇H_kwargs::Union{NamedTuple,Dict}=(
        decoder_loglikelihood=decoder_loglikelihood,
        position_logprior=spherical_logprior,
        momentum_logprior=riemannian_logprior,
        G_inv=G_inv,
    ),
    tempering_schedule::Function=quadratic_tempering,
    latent::Bool=false,
) where {D<:AbstractGaussianDecoder,T<:Float32}
    # Run input through encoder
    encoder_outputs = rhvae.vae.encoder(x)

    # Run reparametrize trick to generate latent variable zₒ
    zₒ = reparameterize(rhvae.vae.encoder, encoder_outputs, n_samples=1)

    # Run leapfrog and tempering steps
    phase_space = general_leapfrog_tempering_step(
        rhvae, x, zₒ;
        K=K, ϵ=ϵ, βₒ=βₒ, ∇H=∇H, ∇H_kwargs=∇H_kwargs,
        tempering_schedule=tempering_schedule
    )

    # Run final zₖ through decoder
    decoder_outputs = rhvae.vae.decoder(phase_space.z_final)

    # Check if latent variables should be returned
    if latent
        return (
            encoder=encoder_outputs,
            decoder=decoder_outputs,
            phase_space=phase_space,
        )
    else
        return decoder_outputs
    end # if
end # function

# ==============================================================================
# Riemannian Hamiltonian ELBO
# ==============================================================================

@doc raw"""
    _log_p̄(
        rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,SimpleDecoder}},
        x::AbstractVector{T},
        hvae_outputs::NamedTuple,
    ) where {T<:Float32}

This is an internal function used in `riemannian_hamiltonian_elbo` to compute
the numerator of the unbiased estimator of the marginal likelihood. The function
computes the sum of the log likelihood of the data given the latent variables,
the log prior of the latent variables, and the log prior of the momentum
variables.

    log p̄ = log p(x | zₖ) + log p(zₖ) + log p(ρₖ(zₖ))

# Arguments
- `rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,SimpleDecoder}}`: The Riemannian
  Hamiltonian Variational Autoencoder (RHVAE) model.
- `x::AbstractVector{T}`: The input data, where `T` is a subtype of `Float32`.
- `hvae_outputs::NamedTuple`: The outputs of the RHVAE, including the final
  latent variables `zₖ` and the final momentum variables `ρₖ`.

# Returns
- `log_p̄::T`: The first term of the log of the unbiased estimator of the
  marginal likelihood.

# Note
This is an internal function and should not be called directly. It is used as
part of the `riemannian_hamiltonian_elbo` function.
"""
function _log_p̄(
    rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,SimpleDecoder}},
    x::AbstractVector{T},
    hvae_outputs::NamedTuple,
) where {T<:Float32}
    # Unpack necessary variables
    µ = hvae_outputs.decoder.µ
    σ = 1.0f0
    zₖ = hvae_outputs.phase_space.z_final
    ρₖ = hvae_outputs.phase_space.ρ_final

    # log p̄ = log p(x | zₖ) + log p(zₖ) + log p(ρₖ)   

    # Compute log p(x | zₖ)
    log_p_x_given_zₖ = -0.5f0 * sum(abs2, (x - μ) / σ) -
                       0.5f0 * length(x) * (2.0f0 * log(σ) + log(2.0f0π))

    # Compute log p(zₖ)
    log_p_zₖ = spherical_logprior(zₖ)

    # Compute log p(ρₖ)
    log_p_ρₖ = riemannian_logprior(rhvae, zₖ, ρₖ)

    return log_p_x_given_zₖ + log_p_zₖ + log_p_ρₖ
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    _log_p̄(
        rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,SimpleDecoder}},
        x::AbstractMatrix{T},
        hvae_outputs::NamedTuple,
    ) where {T<:Float32}

This is an internal function used in `riemannian_hamiltonian_elbo` to compute
the numerator of the unbiased estimator of the marginal likelihood. The function
computes the sum of the log likelihood of the data given the latent variables,
the log prior of the latent variables, and the log prior of the momentum
variables.

    log p̄ = log p(x | zₖ) + log p(zₖ) + log p(ρₖ(zₖ))

# Arguments
- `rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,SimpleDecoder}}`: The Riemannian
  Hamiltonian Variational Autoencoder (RHVAE) model.
- `x::AbstractMatrix{T}`: The input data, where `T` is a subtype of `Float32`.
  Each column represents a data point.
- `hvae_outputs::NamedTuple`: The outputs of the RHVAE, including the final
  latent variables `zₖ` and the final momentum variables `ρₖ`.

# Returns
- `log_p̄::T`: The first term of the log of the unbiased estimator of the
  marginal likelihood.

# Note
This is an internal function and should not be called directly. It is used as
part of the `riemannian_hamiltonian_elbo` function.
"""
function _log_p̄(
    rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,SimpleDecoder}},
    x::AbstractMatrix{T},
    hvae_outputs::NamedTuple,
) where {T<:Float32}
    # Unpack necessary variables
    µ = hvae_outputs.decoder.µ
    σ = 1.0f0
    zₖ = hvae_outputs.phase_space.z_final
    ρₖ = hvae_outputs.phase_space.ρ_final

    # Initialize log_p
    log_p = 0.0f0

    # Iterate over columns
    for i in axes(x, 2)
        # Compute log p(x | zₖ)
        log_p_x_given_zₖ = -0.5f0 * sum(abs2, (x[:, i] - µ[:, i]) / σ) -
                           0.5f0 * size(x, 1) * (2.0f0 * log(σ) + log(2.0f0π))

        # Compute log p(zₖ)
        log_p_zₖ = spherical_logprior(zₖ[:, i])

        # Compute log p(ρₖ)
        log_p_ρₖ = riemannian_logprior(rhvae, zₖ[:, i], ρₖ[:, i])

        # Accumulate results
        log_p += log_p_x_given_zₖ + log_p_zₖ + log_p_ρₖ
    end # for

    return log_p
end # function

# ------------------------------------------------------------------------------

@doc raw"""
        _log_p̄(
                rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLogDecoder}},
                x::AbstractVector{T},
                hvae_outputs::NamedTuple,
        ) where {T<:Float32}

This is an internal function used in `riemannian_hamiltonian_elbo` to compute
the numerator of the unbiased estimator of the marginal likelihood. The function
computes the sum of the log likelihood of the data given the latent variables,
the log prior of the latent variables, and the log prior of the momentum
variables.

        log p̄ = log p(x | zₖ) + log p(zₖ) + log p(ρₖ(zₖ))

# Arguments
- `rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLogDecoder}}`:
    The Riemannian Hamiltonian Variational Autoencoder (RHVAE) model.
- `x::AbstractVector{T}`: The input data, where `T` is a subtype of `Float32`.
- `hvae_outputs::NamedTuple`: The outputs of the RHVAE, including the final
    latent variables `zₖ` and the final momentum variables `ρₖ`.

# Returns
- `log_p̄::T`: The first term of the log of the unbiased estimator of the
    marginal likelihood.

# Note
This is an internal function and should not be called directly. It is used as
part of the `riemannian_hamiltonian_elbo` function.
"""
function _log_p̄(
    rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLogDecoder}},
    x::AbstractVector{T},
    hvae_outputs::NamedTuple,
) where {T<:Float32}
    # Unpack necessary variables
    µ = hvae_outputs.decoder.µ
    logσ = hvae_outputs.decoder.logσ
    σ = exp.(logσ)
    zₖ = hvae_outputs.phase_space.z_final
    ρₖ = hvae_outputs.phase_space.ρ_final

    # log p̄ = log p(x | zₖ) + log p(zₖ) + log p(ρₖ)   

    # Compute log p(x | zₖ)
    log_p_x_given_zₖ = -0.5f0 * sum(abs2, (x - μ) ./ σ) -
                       sum(logσ) -
                       0.5f0 * length(x) * log(2.0f0π)

    # Compute log p(zₖ)
    log_p_zₖ = spherical_logprior(zₖ)

    # Compute log p(ρₖ)
    log_p_ρₖ = riemannian_logprior(rhvae, zₖ, ρₖ)

    return log_p_x_given_zₖ + log_p_zₖ + log_p_ρₖ
end # function

# ------------------------------------------------------------------------------

@doc raw"""
        _log_p̄(
                rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLogDecoder}},
                x::AbstractMatrix{T},
                hvae_outputs::NamedTuple,
        ) where {T<:Float32}

This is an internal function used in `riemannian_hamiltonian_elbo` to compute
the numerator of the unbiased estimator of the marginal likelihood. The function
computes the sum of the log likelihood of the data given the latent variables,
the log prior of the latent variables, and the log prior of the momentum
variables.

        log p̄ = log p(x | zₖ) + log p(zₖ) + log p(ρₖ(zₖ))

# Arguments
- `rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLogDecoder}}`:
  The Riemannian Hamiltonian Variational Autoencoder (RHVAE) model.
- `x::AbstractMatrix{T}`: The input data, where `T` is a subtype of `Float32`.
  Each column represents a data point.
- `hvae_outputs::NamedTuple`: The outputs of the RHVAE, including the final
  latent variables `zₖ` and the final momentum variables `ρₖ`.

# Returns
- `log_p̄::T`: The first term of the log of the unbiased estimator of the
  marginal likelihood.

# Note
This is an internal function and should not be called directly. It is used as
part of the `riemannian_hamiltonian_elbo` function.
"""
function _log_p̄(
    rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLogDecoder}},
    x::AbstractMatrix{T},
    hvae_outputs::NamedTuple,
) where {T<:Float32}
    # Unpack necessary variables
    µ = hvae_outputs.decoder.µ
    logσ = hvae_outputs.decoder.logσ
    σ = exp.(logσ)
    zₖ = hvae_outputs.phase_space.z_final
    ρₖ = hvae_outputs.phase_space.ρ_final

    # Initialize log_p
    log_p = 0.0f0

    # Iterate over columns
    for i in axes(x, 2)
        # Compute log p(x | zₖ)
        log_p_x_given_zₖ = -0.5f0 * sum(abs2, (x[:, i] - µ[:, i]) ./ σ) -
                           sum(logσ[:, i]) -
                           0.5f0 * size(x, 1) * log(2.0f0π)

        # Compute log p(zₖ)
        log_p_zₖ = spherical_logprior(zₖ[:, i])

        # Compute log p(ρₖ)
        log_p_ρₖ = riemannian_logprior(rhvae, zₖ[:, i], ρₖ[:, i])

        # Accumulate results
        log_p += log_p_x_given_zₖ + log_p_zₖ + log_p_ρₖ
    end # for

    return log_p
end # function


# ------------------------------------------------------------------------------

@doc raw"""
        _log_p̄(
                rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLinearDecoder}},
                x::AbstractVector{T},
                hvae_outputs::NamedTuple,
        ) where {T<:Float32}

This is an internal function used in `riemannian_hamiltonian_elbo` to compute
the numerator of the unbiased estimator of the marginal likelihood. The function
computes the sum of the log likelihood of the data given the latent variables,
the log prior of the latent variables, and the log prior of the momentum
variables.

        log p̄ = log p(x | zₖ) + log p(zₖ) + log p(ρₖ(zₖ))

# Arguments
- `rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLinearDecoder}}`:
    The Riemannian Hamiltonian Variational Autoencoder (RHVAE) model.
- `x::AbstractVector{T}`: The input data, where `T` is a subtype of `Float32`.
- `hvae_outputs::NamedTuple`: The outputs of the RHVAE, including the final
    latent variables `zₖ` and the final momentum variables `ρₖ`.

# Returns
- `log_p̄::T`: The first term of the log of the unbiased estimator of the
    marginal likelihood.

# Note
This is an internal function and should not be called directly. It is used as
part of the `riemannian_hamiltonian_elbo` function.
"""
function _log_p̄(
    rhvae::RHVAE{
        <:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLinearDecoder}
    },
    x::AbstractVector{T},
    hvae_outputs::NamedTuple,
) where {T<:Float32}
    # Unpack necessary variables
    µ = hvae_outputs.decoder.µ
    σ = hvae_outputs.decoder.σ
    zₖ = hvae_outputs.phase_space.z_final
    ρₖ = hvae_outputs.phase_space.ρ_final

    # log p̄ = log p(x | zₖ) + log p(zₖ) + log p(ρₖ)   

    # Compute log p(x | zₖ)
    log_p_x_given_zₖ = -0.5f0 * sum(abs2, (x - μ) ./ σ) -
                       sum(log, σ) -
                       0.5f0 * length(x) * log(2.0f0π)

    # Compute log p(zₖ)
    log_p_zₖ = spherical_logprior(zₖ)

    # Compute log p(ρₖ)
    log_p_ρₖ = riemannian_logprior(rhvae, zₖ, ρₖ)

    return log_p_x_given_zₖ + log_p_zₖ + log_p_ρₖ
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    _log_p̄(
        rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLinearDecoder}},
        x::AbstractMatrix{T},
        hvae_outputs::NamedTuple,
    ) where {T<:Float32}

This is an internal function used in `riemannian_hamiltonian_elbo` to compute
the numerator of the unbiased estimator of the marginal likelihood. The function
computes the sum of the log likelihood of the data given the latent variables,
the log prior of the latent variables, and the log prior of the momentum
variables.

    log p̄ = log p(x | zₖ) + log p(zₖ) + log p(ρₖ(zₖ))

# Arguments
- `rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLinearDecoder}}`:
  The Riemannian Hamiltonian Variational Autoencoder (RHVAE) model.
- `x::AbstractMatrix{T}`: The input data, where `T` is a subtype of `Float32`.
  Each column represents a data point.
- `hvae_outputs::NamedTuple`: The outputs of the RHVAE, including the final
  latent variables `zₖ` and the final momentum variables `ρₖ`.

# Returns
- `log_p̄::T`: The first term of the log of the unbiased estimator of the
  marginal likelihood.

# Note
This is an internal function and should not be called directly. It is used as
part of the `riemannian_hamiltonian_elbo` function.
"""
function _log_p̄(
    rhvae::RHVAE{<:VAE{<:AbstractGaussianEncoder,<:AbstractGaussianLinearDecoder}},
    x::AbstractMatrix{T},
    hvae_outputs::NamedTuple,
) where {T<:Float32}
    # Unpack necessary variables
    µ = hvae_outputs.decoder.µ
    σ = hvae_outputs.decoder.σ
    zₖ = hvae_outputs.phase_space.z_final
    ρₖ = hvae_outputs.phase_space.ρ_final

    # Initialize log_p
    log_p = 0.0f0

    # Iterate over columns
    for i in axes(x, 2)
        # Compute log p(x | zₖ)
        log_p_x_given_zₖ = -0.5f0 * sum(abs2, (x[:, i] - µ[:, i]) ./ σ) -
                           sum(log, σ[:, i]) -
                           0.5f0 * size(x, 1) * log(2.0f0π)

        # Compute log p(zₖ)
        log_p_zₖ = spherical_logprior(zₖ[:, i])

        # Compute log p(ρₖ)
        log_p_ρₖ = riemannian_logprior(rhvae, zₖ[:, i], ρₖ[:, i])

        # Accumulate results
        log_p += log_p_x_given_zₖ + log_p_zₖ + log_p_ρₖ
    end # for

    return log_p
end # function

# ------------------------------------------------------------------------------

function _log_q̄(
    rhvae::RHVAE{
        <:VAE{<:AbstractGaussianLogEncoder,<:AbstractVariationalDecoder}
    },
    x::AbstractVector{T},
    hvae_outputs::NamedTuple,
    βₒ::T
) where {T<:Float32}
    # Unpack necessary variables
    µ = hvae_outputs.encoder.µ
    logσ = hvae_outputs.encoder.logσ
    zₒ = hvae_outputs.phase_space.z_init
    ρₒ = hvae_outputs.phase_space.ρ_init

    # log q̄ = log q(zₒ) + log p(ρₒ) - d/2 log(βₒ)

    # Compute log q(zₒ)
    log_q_z = -0.5f0 * sum(abs2, (zₒ - μ) ./ exp.(logσ)) -
              sum(logσ) - 0.5f0 * length(zₒ) * log(2.0f0π)

    # Compute log p(ρₒ)
    log_p_ρ = riemannian_logprior(rhvae, zₒ, ρₒ)

    return log_q_z + log_p_ρ - 0.5f0 * length(zₒ) * log(βₒ)
end # function
