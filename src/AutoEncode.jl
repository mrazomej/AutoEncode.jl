module AutoEncode

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Import packages
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
import Flux
import Random
import Distributions

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Abstract Types
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

@doc raw"""
    AbstractAutoEncoder

This is an abstract type that serves as a parent for all autoencoder models in
this package.

An autoencoder is a type of artificial neural network used for learning
efficient codings of input data. It consists of an encoder, which compresses the
input data, and a decoder, which reconstructs the original data from the
compressed representation.

Subtypes of this abstract type should define specific types of autoencoders,
such as standard Auto Encoders, Variational AutoEncoders (VAEs), etc. (more to
be added).
"""
abstract type AbstractAutoEncoder end

@doc raw"""
    AbstractDeterministicAutoEncoder <: AbstractAutoEncoder

This is an abstract type that serves as a parent for all deterministic
autoencoder models in this package.

A deterministic autoencoder is a type of autoencoder where the encoding and
decoding processes are deterministic functions. This contrasts with stochastic
or variational autoencoders, where the encoding process involves a random
sampling step.
"""
abstract type AbstractDeterministicAutoEncoder <: AbstractAutoEncoder end

@doc raw"""
    AbstractVariationalAutoEncoder <: AbstractAutoEncoder

This is an abstract type that serves as a parent for all variational autoencoder
models in this package.

A variational autoencoder (VAE) is a type of autoencoder that adds a
probabilistic twist to autoencoding. Instead of learning a deterministic
function for the encoding, a VAE learns the parameters of a probability
distribution representing the data. The encoding process then involves sampling
from this distribution.

Subtypes of this abstract type should define specific types of variational
autoencoders, such as Standard VAEs, InfoMaxVAEs, or Hamiltonian VAEs.
"""
abstract type AbstractVariationalAutoEncoder <: AbstractAutoEncoder end

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
    AbstractDecoder

This is an abstract type that serves as a parent for all decoder models in this
package.

A decoder is part of an autoencoder model. It takes a lower-dimensional
representation produced by the encoder and reconstructs the original input data
from it. The goal of the decoder is to produce a reconstruction that is as close
as possible to the original input.

Subtypes of this abstract type should define specific types of decoders, such as
deterministic decoders, variational decoders, or other specialized decoder
types.
"""
abstract type AbstractDecoder end

@doc raw"""
    AbstractDeterministicDecoder <: AbstractDecoder

This is an abstract type that serves as a parent for all deterministic decoder
models in this package.

A deterministic decoder is a type of decoder that provides a deterministic
mapping from the lower-dimensional representation to the reconstructed input
data. This contrasts with stochastic or variational decoders, where the decoding
process may involve a random sampling step.

Subtypes of this abstract type should define specific types of deterministic
decoders, such as linear decoders, non-linear decoders, or other specialized
deterministic decoder types.
"""
abstract type AbstractDeterministicDecoder <: AbstractDecoder end

@doc raw"""
    AbstractVariationalDecoder <: AbstractDecoder

This is an abstract type that serves as a parent for all variational decoder
models in this package.

A variational decoder is a type of decoder that maps the lower-dimensional
representation to the parameters of a probability distribution from which the
reconstructed input data is sampled. This introduces stochasticity into the
model.

Subtypes of this abstract type should define specific types of variational
decoders, such as Gaussian decoders, or other specialized variational decoder
types.
"""
abstract type AbstractVariationalDecoder <: AbstractDecoder end

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Include Utils module
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

module utils
include("utils.jl")
end # submodule

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Add AEs module
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

module AEs
include("ae.jl")
end # submodule

# Export AE structure
using .AEs: AE, SimpleAE

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Add VAEs module
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

module VAEs
include("vae.jl")
end # submodule

# Export VAE structs
using .VAEs: VAE, JointLogEncoder, SimpleDecoder, JointLogDecoder,
    SplitLogDecoder, JointDecoder, SplitDecoder

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Add InfoMaxVAEs module
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

module InfoMaxVAEs
include("infomaxvae.jl")
end # submodule

# Export AE structure
using .InfoMaxVAEs: InfoMaxVAE

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Include module to fit a Radial Basis Function (RBF) network
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

module RBFs
include("rbf.jl")
end # submodule

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Include module for Hamiltonian Variational Autoencoders (HVAEs)
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

module HVAEs
include("hvae.jl")
end # submodule

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Include Differential Geometry Module
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

module diffgeo
include("diffgeo.jl")
end # submodule

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Include Regularization Functions module
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

module regularization
include("regularization.jl")
end # submodule

# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Add IRMAEs module
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

# module IRMAEs
# include("irmae.jl")
# end # submodule

# # Export AE structure
# using .IRMAEs: IRMAE, SimpleIRMAE



# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #
# Add MMDVAEs (alias InfoVAEs) module
# %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% #

# Note: This module uses the VAEs.VAE struct as the basis

# module MMDVAEs
# include("mmdvae.jl")
# end # submodule

end # module