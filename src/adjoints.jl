# Import Zygote
import Zygote
# Import FillArrays
using FillArrays: Fill


# ==============================================================================
# Define Zygote.@adjoint for FillArrays.fill
# ==============================================================================

# Note: This is needed because the specific type of FillArrays.fill does not
# have a Zygote.@adjoint function defined. This causes an error when trying to
# backpropagate through the RHVAE.

# Define the Zygote.@adjoint function for the FillArrays.fill method.
# The function takes a matrix `x` of type Float32 and a size `sz` as input.
Zygote.@adjoint function (::Type{T})(x::Matrix{Float32}, sz) where {T<:Fill}
    # Define the backpropagation function for the adjoint. The function takes a
    # gradient `Δ` as input and returns the sum of the gradient and `nothing`.
    back(Δ::AbstractArray) = (sum(Δ), nothing)
    # Define the backpropagation function for the adjoint. The function takes a
    # gradient `Δ` as input and returns the value of `Δ` and `nothing`.
    back(Δ::NamedTuple) = (Δ.value, nothing)
    # Return the result of the FillArrays.fill method and the backpropagation
    # function.
    return Fill(x, sz), back
end # @adjoint

