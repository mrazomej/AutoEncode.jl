# AutoEncoderToolkit.jl

[![Build Status](https://github.com/mrazomej/AutoEncoderToolkit.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/mrazomej/AutoEncoderToolkit.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![codecov](https://codecov.io/gh/mrazomej/AutoEncoderToolkit.jl/graph/badge.svg?token=9DKTMW94G5)](https://codecov.io/gh/mrazomej/AutoEncoderToolkit.jl)
[![status](https://joss.theoj.org/papers/ef5c3f45415c56d77ae836cac422e0df/status.svg)](https://joss.theoj.org/papers/ef5c3f45415c56d77ae836cac422e0df)

> **Note**: The build status above shows `failing` because some tests are
> failing only when running on GitHub Actions. Locally, all tests pass. The
> error  in Github Actions shows up when testing the computation of loss
> function gradients as:
>
> `Got exception outside of a @test`
>
> `BoundsError: attempt to access 16-element Vector{UInt8} at index [0]`
>
> PRs to fix this issue are welcome.

Welcome to the `AutoEncoderToolkit.jl` GitHub repository. This package provides
a simple interface for training and using [Flux.jl](https://fluxml.ai)-based
autoencoders and variational autoencoders in Julia.

## Installation

You can install `AutoEncoderToolkit.jl` using the Julia package manager. From
the Julia REPL, type `]` to enter the Pkg REPL mode and run:

```julia
add AutoEncoderToolkit
```

## Design

The idea behind `AutoEncoderToolkit.jl` is to take advantage of Julia's multiple
dispatch to provide a simple and flexible interface for training and using
different types of autoencoders. The package is designed to be modular and allow
the user to easily define and test custom encoder and decoder architectures.
Moreover, when it comes to variational autoencoders, `AutoEncoderToolkit.jl`
takes a probabilistic perspective, where the type of encoders and decoders
defines (via multiple dispatch) the corresponding distribution used within the
corresponding loss function.

For more information, please refer to the
[documentation](https://mrazomej.github.io/AutoEncoderToolkit.jl/).

## Implemented Autoencoders

| model                      | module        | description                                                    |
| -------------------------- | ------------- | -------------------------------------------------------------- |
| Autoencoder                | `AEs`         | Vanilla deterministic autoencoder                              |
| Variational Autoencoder    | `VAEs`        | Vanilla variational autoencoder                                |
| β-VAE                      | `VAEs`        | beta-VAE to weigh the reconstruction vs. KL divergence in ELBO |
| MMD-VAEs                   | `MMDs`        | Maximum-Mean Discrepancy Variational Autoencoders              |
| InfoMax-VAEs               | `InfoMaxVAEs` | Information Maximization Variational Autoencoders              |
| Hamiltonian VAE            | `HVAEs`       | Hamiltonian Variational Autoencoders                           |
| Riemannian Hamiltonian-VAE | `RHVAEs`      | Riemannian-Hamiltonian Variational Autoencoder                 |
