# Import ML libraries
import Flux

# ==============================================================================
# Encoder abstract types
# ==============================================================================

@doc raw"""
    AbstractEncoder

This is an abstract type that serves as a parent for all encoder models in this
package.

An encoder is part of an autoencoder model. It takes input data and compresses
it into a lower-dimensional representation. This compressed representation often
captures the most salient features of the input data.

Subtypes of this abstract type should define specific types of encoders, such as
deterministic encoders, variational encoders, or other specialized encoder
types.
"""
abstract type AbstractEncoder end

@doc raw"""
    AbstractDeterministicEncoder <: AbstractEncoder

This is an abstract type that serves as a parent for all deterministic encoder
models in this package.

A deterministic encoder is a type of encoder that provides a deterministic
mapping from the input data to a lower-dimensional representation. This
contrasts with stochastic or variational encoders, where the encoding process
involves a random sampling step.

Subtypes of this abstract type should define specific types of deterministic
encoders, such as linear encoders, non-linear encoders, or other specialized
deterministic encoder types.
"""
abstract type AbstractDeterministicEncoder <: AbstractEncoder end

@doc raw"""
    AbstractVariationalEncoder <: AbstractEncoder

This is an abstract type that serves as a parent for all variational encoder
models in this package.

A variational encoder is a type of encoder that maps input data to the
parameters of a probability distribution in a lower-dimensional latent space.
The encoding process involves a random sampling step from this distribution,
which introduces stochasticity into the model.

Subtypes of this abstract type should define specific types of variational
encoders, such as Gaussian encoders, or other specialized variational encoder
types.
"""
abstract type AbstractVariationalEncoder <: AbstractEncoder end

@doc raw"""
    AbstractGaussianEncoder <: AbstractVariationalEncoder

This is an abstract type that serves as a parent for all Gaussian encoder models
in this package.

A Gaussian encoder is a type of variational encoder that maps the
higher-dimensional input data to the parameters of a Gaussian distribution from
which the lower-dimensional latent variables are sampled. This introduces
stochasticity into the model.

Subtypes of this abstract type should define specific types of Gaussian
encoders, or other specialized Gaussian encoder types.
"""
abstract type AbstractGaussianEncoder <: AbstractVariationalEncoder end

@doc raw"""
    AbstractGaussianLinearEncoder <: AbstractGaussianEncoder

An abstract type representing a Gaussian linear encoder in a variational autoencoder.

# Description
A Gaussian linear encoder is a type of encoder that maps inputs to a Gaussian distribution in the latent space. Unlike a standard Gaussian encoder, which typically returns the log of the standard deviation of the Gaussian distribution, a Gaussian linear encoder returns the standard deviation directly.

This abstract type is used as a base for all Gaussian linear encoders. Specific implementations of Gaussian linear encoders should subtype this abstract type and implement the necessary methods.

# Note
When implementing a subtype, ensure that the encoder returns the standard deviation of the Gaussian distribution directly, not the log of the standard deviation.
"""
abstract type AbstractGaussianLinearEncoder <: AbstractGaussianEncoder end

@doc raw"""
    AbstractGaussianLogEncoder <: AbstractGaussianEncoder

An abstract type representing a Gaussian log encoder in a variational
autoencoder.

# Description
A Gaussian log encoder is a type of encoder that maps inputs to a Gaussian
distribution in the latent space. Unlike a Gaussian linear encoder, which
returns the standard deviation of the Gaussian distribution directly, a Gaussian
log encoder returns the log of the standard deviation.

This abstract type is used as a base for all Gaussian log encoders. Specific
implementations of Gaussian log encoders should subtype this abstract type and
implement the necessary methods.

# Note
When implementing a subtype, ensure that the encoder returns the log of the
standard deviation of the Gaussian distribution, not the standard deviation
directly.
"""
abstract type AbstractGaussianLogEncoder <: AbstractGaussianEncoder end

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Concrete Deterministic Encoders
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

@doc raw"""
`struct Encoder`

Default encoder function for deterministic autoencoders. The `encoder` network
is used to map the input data directly into the latent space representation.

# Fields
- `encoder::Flux.Chain`: The primary neural network used to process input data
  and map it into a latent space representation.

# Example
```julia
enc = Encoder(Flux.Chain(Dense(784, 400, relu), Dense(400, 20)))
```
"""
struct Encoder <: AbstractDeterministicEncoder
    encoder::Flux.Chain
end # struct

# Mark function as Flux.Functors.@functor so that Flux.jl allows for training
Flux.@functor Encoder

@doc raw"""
    Encoder(n_input, n_latent, latent_activation, encoder_neurons, 
            encoder_activation; init=Flux.glorot_uniform)

Construct and initialize an `Encoder` struct that defines an encoder network for
a deterministic autoencoder.

# Arguments
- `n_input::Int`: The dimensionality of the input data.
- `n_latent::Int`: The dimensionality of the latent space.
- `encoder_neurons::Vector{<:Int}`: A vector specifying the number of neurons in
  each layer of the encoder network.
- `encoder_activation::Vector{<:Function}`: Activation functions corresponding
  to each layer in the `encoder_neurons`.
- `latent_activation::Function`: Activation function for the latent space layer.

## Optional Keyword Arguments
- `init::Function=Flux.glorot_uniform`: The initialization function used for the
  neural network weights.

# Returns
- An `Encoder` struct initialized based on the provided arguments.

# Examples
```julia
encoder = Encoder(784, 20, tanh, [400], [relu])
````
# Notes
The length of encoder_neurons should match the length of encoder_activation,
ensuring that each layer in the encoder has a corresponding activation function.
"""
function Encoder(
    n_input::Int,
    n_latent::Int,
    encoder_neurons::Vector{<:Int},
    encoder_activation::Vector{<:Function},
    latent_activation::Function;
    init::Function=Flux.glorot_uniform
)
    # Ensure there's a matching activation function for every layer in the encoder
    if length(encoder_activation) != length(encoder_neurons)
        error("Each layer needs exactly one activation function in encoder")
    end # if
    # Initialize list with encoder layers
    layers = []

    # Iterate through encoder layers and add them to the list
    for i = 1:length(encoder_neurons)
        # For the first layer
        if i == 1
            push!(
                layers,
                Flux.Dense(
                    n_input => encoder_neurons[i],
                    encoder_activation[i];
                    init=init
                )
            )
        else
            # For subsequent layers
            push!(
                layers,
                Flux.Dense(
                    encoder_neurons[i-1] => encoder_neurons[i],
                    encoder_activation[i];
                    init=init
                )
            )
        end # if
    end # for

    # Add the layer mapping to the latent space, with its specified activation
    # function
    push!(
        layers,
        Flux.Dense(
            encoder_neurons[end] => n_latent,
            latent_activation;
            init=init
        )
    )

    return Encoder(Flux.Chain(layers...))
end # function

@doc raw"""
    (encoder::Encoder)(x)

Forward propagate the input `x` through the `Encoder` to obtain the encoded
representation in the latent space.

# Arguments
- `x::Array{Float32}`: Input data to be encoded.

# Returns
- `z`: Encoded representation of the input data in the latent space.

# Description
This method allows for a direct call on an instance of `Encoder` with the input
data `x`. It runs the input through the encoder network and outputs the encoded
representation in the latent space.

# Example
```julia
enc = Encoder(...)
z = enc(some_input)
```
# Note

Ensure that the input x matches the expected dimensionality of the encoder's
input layer.
"""
function (encoder::Encoder)(x::AbstractVecOrMat{Float32})
    # Run input through the encoder network to obtain the encoded representation
    return encoder.encoder(x)
end # function

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Concrete Variational Encoders
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

# ==============================================================================
# `struct JointLogEncoder <: AbstractVariationalEncoder`
# ==============================================================================

@doc raw"""
`struct JointLogEncoder <: AbstractGaussianLogEncoder`

Default encoder function for variational autoencoders where the same `encoder`
network is used to map to the latent space mean `µ` and log standard deviation
`logσ`.

# Fields
- `encoder::Flux.Chain`: The primary neural network used to process input data
  and map it into a latent space representation.
- `µ::Flux.Dense`: A dense layer mapping from the output of the `encoder` to the
  mean of the latent space.
- `logσ::Flux.Dense`: A dense layer mapping from the output of the `encoder` to
  the log standard deviation of the latent space.

# Example
```julia
enc = JointLogEncoder(
    Flux.Chain(Dense(784, 400, relu)), Flux.Dense(400, 20), Flux.Dense(400, 20)
)
"""
struct JointLogEncoder <: AbstractGaussianLogEncoder
    encoder::Flux.Chain
    µ::Flux.Dense
    logσ::Flux.Dense
end # struct

# Mark function as Flux.Functors.@functor so that Flux.jl allows for training
Flux.@functor JointLogEncoder

@doc raw"""
    JointLogEncoder(n_input, n_latent, encoder_neurons, encoder_activation, 
                 latent_activation; init=Flux.glorot_uniform)

Construct and initialize a `JointLogEncoder` struct that defines an encoder
network for a variational autoencoder.

# Arguments
- `n_input::Int`: The dimensionality of the input data.
- `n_latent::Int`: The dimensionality of the latent space.
- `encoder_neurons::Vector{<:Int}`: A vector specifying the number of neurons in
  each layer of the encoder network.
- `encoder_activation::Vector{<:Function}`: Activation functions corresponding
  to each layer in the `encoder_neurons`.
- `latent_activation::Function`: Activation function for the latent space layers
  (both µ and logσ).

## Optional Keyword Arguments
- `init::Function=Flux.glorot_uniform`: The initialization function used for the
  neural network weights.

# Returns
- A `JointLogEncoder` struct initialized based on the provided arguments.

# Examples
```julia
encoder = JointLogEncoder(784, 20, [400], [relu], tanh)
```

# Notes
The length of encoder_neurons should match the length of encoder_activation,
ensuring that each layer in the encoder has a corresponding activation function.
"""
function JointLogEncoder(
    n_input::Int,
    n_latent::Int,
    encoder_neurons::Vector{<:Int},
    encoder_activation::Vector{<:Function},
    latent_activation::Function;
    init::Function=Flux.glorot_uniform
)
    # Check there's enough activation functions for all layers
    if (length(encoder_activation) != length(encoder_neurons))
        error("Each layer needs exactly one activation function")
    end # if

    # Initialize list with encoder layers
    encoder_layers = Array{Flux.Dense}(undef, length(encoder_neurons))

    # Loop through layers   
    for i in eachindex(encoder_neurons)
        # Check if it is the first layer
        if i == 1
            # Set first layer from input to encoder with activation
            encoder_layers[i] = Flux.Dense(
                n_input => encoder_neurons[i], encoder_activation[i]; init=init
            )
        else
            # Set middle layers from input to encoder with activation
            encoder_layers[i] = Flux.Dense(
                encoder_neurons[i-1] => encoder_neurons[i],
                encoder_activation[i];
                init=init
            )
        end # if
    end # for

    # Define layer that maps from encoder to latent space with activation
    µ_layer = Flux.Dense(
        encoder_neurons[end] => n_latent, latent_activation; init=init
    )
    logσ_layer = Flux.Dense(
        encoder_neurons[end] => n_latent, latent_activation; init=init
    )

    # Initialize decoder
    return JointLogEncoder(Flux.Chain(encoder_layers...), µ_layer, logσ_layer)
end # function

@doc raw"""
    JointLogEncoder(n_input, n_latent, encoder_neurons, encoder_activation, 
                 latent_activation; init=Flux.glorot_uniform)

Construct and initialize a `JointLogEncoder` struct that defines an encoder
network for a variational autoencoder.

# Arguments
- `n_input::Int`: The dimensionality of the input data.
- `n_latent::Int`: The dimensionality of the latent space.
- `encoder_neurons::Vector{<:Int}`: A vector specifying the number of neurons in
  each layer of the encoder network.
- `encoder_activation::Vector{<:Function}`: Activation functions corresponding
  to each layer in the `encoder_neurons`.
- `latent_activation::Vector{<:Function}`: Activation functions for the latent
  space layers (both µ and logσ).

## Optional Keyword Arguments
- `init::Function=Flux.glorot_uniform`: The initialization function used for the
  neural network weights.

# Returns
- A `JointLogEncoder` struct initialized based on the provided arguments.

# Examples
```julia
encoder = JointLogEncoder(784, 20, [400], [relu], tanh)
```

# Notes
The length of encoder_neurons should match the length of encoder_activation,
ensuring that each layer in the encoder has a corresponding activation function.
"""
function JointLogEncoder(
    n_input::Int,
    n_latent::Int,
    encoder_neurons::Vector{<:Int},
    encoder_activation::Vector{<:Function},
    latent_activation::Vector{<:Function};
    init::Function=Flux.glorot_uniform
)
    # Check there's enough activation functions for all layers
    if (length(encoder_activation) != length(encoder_neurons))
        error("Each layer needs exactly one activation function")
    end # if

    # Initialize list with encoder layers
    encoder_layers = Array{Flux.Dense}(undef, length(encoder_neurons))

    # Loop through layers   
    for i in eachindex(encoder_neurons)
        # Check if it is the first layer
        if i == 1
            # Set first layer from input to encoder with activation
            encoder_layers[i] = Flux.Dense(
                n_input => encoder_neurons[i], encoder_activation[i]; init=init
            )
        else
            # Set middle layers from input to encoder with activation
            encoder_layers[i] = Flux.Dense(
                encoder_neurons[i-1] => encoder_neurons[i],
                encoder_activation[i];
                init=init
            )
        end # if
    end # for

    # Define layer that maps from encoder to latent space with activation
    µ_layer = Flux.Dense(
        encoder_neurons[end] => n_latent, latent_activation[1]; init=init
    )
    logσ_layer = Flux.Dense(
        encoder_neurons[end] => n_latent, latent_activation[2]; init=init
    )

    # Initialize decoder
    return JointLogEncoder(Flux.Chain(encoder_layers...), µ_layer, logσ_layer)
end # function

@doc raw"""
        (encoder::JointLogEncoder)(x)

This method forward propagates the input `x` through the `JointLogEncoder` to
compute the mean (`mu`) and log standard deviation (`logσ`) of the latent space.

# Arguments
- `x::Array{Float32}`: The input data to be encoded.

# Returns
- A NamedTuple `(µ=µ, logσ=logσ,)` where:
    - `µ`: The mean of the latent space. This is computed by passing the input
      through the encoder and subsequently through the `µ` layer.  
    - `logσ`: The log standard deviation of the latent space. This is computed
      by passing the input through the encoder and subsequently through the
      `logσ` layer.

# Description
This method allows for a direct call on an instance of `JointLogEncoder` with
the input data `x`. It first processes the input through the encoder network,
then maps the output of the last encoder layer to both the mean and log standard
deviation of the latent space.

# Example
```julia
je = JointLogEncoder(...)
mu, logσ = je(some_input)
```

# Note
Ensure that the input x matches the expected dimensionality of the encoder's
input layer.
"""
function (encoder::JointLogEncoder)(
    x::AbstractArray{T}
) where {T<:Number}
    # Run input to encoder network
    h = encoder.encoder(x)
    # Map from last encoder layer to latent space mean
    µ = encoder.µ(h)
    # Map from last encoder layer to latent space log standard deviation
    logσ = encoder.logσ(h)

    # Drop dimensions of size 1 from µ and logσ
    µ = dropdims(µ, dims=tuple(findall(size(µ) .== 1)...))
    logσ = dropdims(logσ, dims=tuple(findall(size(logσ) .== 1)...))

    # Return description of latent variables
    return (µ=µ, logσ=logσ,)
end # function

# ==============================================================================
# `struct JointEncoder <: AbstractVariationalEncoder`
# ==============================================================================

@doc raw"""
`struct JointEncoder <: AbstractGaussianLinearEncoder`

Encoder function for variational autoencoders where the same `encoder` network
is used to map to the latent space mean `µ` and standard deviation `σ`.

# Fields
- `encoder::Flux.Chain`: The primary neural network used to process input data
  and map it into a latent space representation.
- `µ::Flux.Dense`: A dense layer mapping from the output of the `encoder` to the
  mean of the latent space.
- `σ::Flux.Dense`: A dense layer mapping from the output of the `encoder` to the
  standard deviation of the latent space.

# Example
```julia
enc = JointEncoder(
    Flux.Chain(Dense(784, 400, relu)), Flux.Dense(400, 20), Flux.Dense(400, 20)
)
"""
struct JointEncoder <: AbstractGaussianLinearEncoder
    encoder::Flux.Chain
    µ::Flux.Dense
    σ::Flux.Dense
end # struct

# Mark function as Flux.Functors.@functor so that Flux.jl allows for training
Flux.@functor JointEncoder

@doc raw"""
    JointEncoder(n_input, n_latent, encoder_neurons, encoder_activation, 
                 latent_activation; init=Flux.glorot_uniform)

Construct and initialize a `JointLogEncoder` struct that defines an encoder
network for a variational autoencoder.

# Arguments
- `n_input::Int`: The dimensionality of the input data.
- `n_latent::Int`: The dimensionality of the latent space.
- `encoder_neurons::Vector{<:Int}`: A vector specifying the number of neurons in
  each layer of the encoder network.
- `encoder_activation::Vector{<:Function}`: Activation functions corresponding
  to each layer in the `encoder_neurons`.
- `latent_activation::Vector{<:Function}`: Activation function for the latent
  space layers. This vector must contain the activation for both µ and logσ.

## Optional Keyword Arguments
- `init::Function=Flux.glorot_uniform`: The initialization function used for the
  neural network weights.

# Returns
- A `JointEncoder` struct initialized based on the provided arguments.

# Examples
```julia
encoder = JointEncoder(784, 20, [400], [relu], [tanh, softplus])
```

# Notes
The length of encoder_neurons should match the length of encoder_activation,
ensuring that each layer in the encoder has a corresponding activation function.
"""
function JointEncoder(
    n_input::Int,
    n_latent::Int,
    encoder_neurons::Vector{<:Int},
    encoder_activation::Vector{<:Function},
    latent_activation::Vector{<:Function};
    init::Function=Flux.glorot_uniform
)
    # Check there's enough activation functions for all layers
    if (length(encoder_activation) != length(encoder_neurons))
        error("Each layer needs exactly one activation function")
    end # if

    # Initialize list with encoder layers
    encoder_layers = Array{Flux.Dense}(undef, length(encoder_neurons))

    # Loop through layers   
    for i in eachindex(encoder_neurons)
        # Check if it is the first layer
        if i == 1
            # Set first layer from input to encoder with activation
            encoder_layers[i] = Flux.Dense(
                n_input => encoder_neurons[i], encoder_activation[i]; init=init
            )
        else
            # Set middle layers from input to encoder with activation
            encoder_layers[i] = Flux.Dense(
                encoder_neurons[i-1] => encoder_neurons[i],
                encoder_activation[i];
                init=init
            )
        end # if
    end # for

    # Define layer that maps from encoder to latent space with activation
    µ_layer = Flux.Dense(
        encoder_neurons[end] => n_latent, latent_activation[1]; init=init
    )
    logσ_layer = Flux.Dense(
        encoder_neurons[end] => n_latent, latent_activation[2]; init=init
    )

    # Initialize decoder
    return JointEncoder(Flux.Chain(encoder_layers...), µ_layer, logσ_layer)
end # function

@doc raw"""
        (encoder::JointEncoder)(x)

Forward propagate the input `x` through the `JointEncoder` to obtain the mean
(`µ`) and standard deviation (`σ`) of the latent space.

# Arguments
- `x::AbstractVecOrMat{Float32}`: Input data to be encoded.

# Returns
- A NamedTuple `(µ=µ, σ=σ,)` where:
    - `µ`: Mean of the latent space after passing the input through the encoder
      and subsequently through the `µ` layer.
    - `σ`: Standard deviation of the latent space after passing the input
      through the encoder and subsequently through the `σ` layer.

# Description
This method allows for a direct call on an instance of `JointEncoder` with the
input data `x`. It first runs the input through the encoder network, then maps
the output of the last encoder layer to both the mean and standard deviation of
the latent space.

# Example
```julia
je = JointEncoder(...)
µ, σ = je(some_input)
```
# Note
Ensure that the input x matches the expected dimensionality of the encoder's
input layer.
"""
function (encoder::JointEncoder)(
    x::AbstractArray{T}
) where {T<:Number}
    # Run input to encoder network
    h = encoder.encoder(x)
    # Map from last encoder layer to latent space mean
    µ = encoder.µ(h)
    # Map from last encoder layer to latent space log standard deviation
    σ = encoder.logσ(h)

    # Drop dimensions of size 1 from µ and σ
    µ = dropdims(µ, dims=tuple(findall(size(µ) .== 1)...))
    σ = dropdims(σ, dims=tuple(findall(size(σ) .== 1)...))

    # Return description of latent variables
    return (µ=µ, σ=σ,)
end # function

# ==============================================================================
# Functions to compute log-probabilities
# ==============================================================================

# ==============================================================================
# Function to compute log prior
# ==============================================================================

@doc raw"""
    spherical_logprior(
        z::AbstractVector{T},
        σ::T=1.0f0,
    ) where {T<:AbstractFloat}

Computes the log-prior of the latent variable `z` under a spherical Gaussian
distribution with zero mean and standard deviation `σ`.

# Arguments
- `z::AbstractVector{T}`: The latent variable for which the log-prior is to be
  computed.
- `σ::T=1.0f0`: The standard deviation of the spherical Gaussian distribution.
  Defaults to `1.0f0`.

# Returns
- `log_prior::Float32`: The computed log-prior of the latent variable `z`.

# Description
The function computes the log-prior of the latent variable `z` under a spherical
Gaussian distribution with zero mean and standard deviation `σ`. The log-prior
is computed using the formula for the log-prior of a Gaussian distribution.

# Note
Ensure the dimension of `z` matches the expected dimensionality of the latent
space.
"""
function spherical_logprior(
    z::AbstractVector{T},
    σ::AbstractFloat=1.0f0,
) where {T<:AbstractFloat}
    # Convert to type T
    σ = convert(T, σ)
    # Compute log-prior
    log_prior = -0.5f0 * sum(abs2, z / σ) -
                0.5f0 * length(z) * (2.0f0 * log(σ) + log(2.0f0π))

    return log_prior
end # function

# ------------------------------------------------------------------------------

@doc raw"""
    spherical_logprior(
        z::AbstractMatrix{T},
        σ::T=1.0f0,
    ) where {T<:AbstractFloat}

Computes the log-prior of the latent variable `z` under a spherical Gaussian
distribution with zero mean and standard deviation `σ`.

# Arguments
- `z::AbstractMatrix{T}`: The latent variable for which the log-prior is to be
  computed. Each column of `z` represents a different latent variable.
- `σ::T=1.0f0`: The standard deviation of the spherical Gaussian distribution.
  Defaults to `1.0f0`.

# Returns
- `log_prior::Float32`: The computed log-prior(s) of the latent variable `z`.

# Description
The function computes the log-prior of the latent variable `z` under a spherical
Gaussian distribution with zero mean and standard deviation `σ`. The log-prior
is computed using the formula for the log-prior of a Gaussian distribution.

# Note
Ensure the dimension of `z` matches the expected dimensionality of the latent
space.
"""
function spherical_logprior(
    z::AbstractMatrix{T},
    σ::AbstractFloat=1.0f0,
) where {T<:AbstractFloat}
    # Convert to type T
    σ = convert(T, σ)

    # Compute log-prior
    log_prior = [
        begin
            -0.5f0 * sum(abs2, z[:, i] / σ) -
            0.5f0 * length(z[:, i]) * (2.0f0 * log(σ) + log(2.0f0π))
        end for i = 1:size(z, 2)
    ]

    return log_prior
end # function