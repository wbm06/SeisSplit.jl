# Functions for the minimum-eigenvalue method

"""
    splitting(t1, t2, window_start=starttime(t1), window_end=endtime(t1); nphi=$SPLIT_NPHI, ndt=$SPLIT_NDT, dt_max=$SPLIT_DT_MAX, xcorr=true) -> results

Perform a search over a pair of Seis traces, `t1` and `t2`, for the smallest value of the
minimum eigenvalue of the covariance matrix between the traces, for a set of `nphi`×`ndt`
shear wave splitting operators, up to `dt_max` s.

## Output

`results` is a `SeisSplit.Result` containing:

- `phi`: The set of fast shear wave orientations in °
- `dt`: The set of delays times in s
- `lam1`: The larger eigenvalues at each [phi,dt] point
- `lam2`: The smaller eigenvalues at each point
- `phi_best` and `dphi`: The best ϕ and its 1σ uncertainty.  ϕ is measured
  clockwise from local north (towards east) in °.
- `dt_best` and `ddt`: The best δt and its 1σ uncertainty, in s
- `spol` and `dspol`: The source polarisation and an estimate of its uncertainty for the
  best-fitting ϕ and δt.  `spol` is given in ° clockwise of local north.
- `trace1` and `trace2`, the original input traces, where `trace2` is clockwise of `trace1`
- `window_start`, `window_end`, the analysis time window end points.
- `ndf`, the number of degrees of freedom in the signal.

If `xcorr` is `true`, then the rotation correlation map for the pair
of traces is also computed and the following additional fields are
present in `results`:

- `xcorr_phi`: Angles over which rotation correlation was calculated (°)
- `xcorr_dt`: Delay times over which rotation correlation was calculated (s)
- `xcorr_map`: Cross correlation at each [phi,dt] point
- `xcorr_phi_best`: Fast orientation of maximum cross correlation (°)
- `xcorr_dt_best`: Delay time of maximum cross correlation (s)
"""
function splitting(t1::Seis.Trace{T,V}, t2::Seis.Trace{T,V},
                   window_start=Seis.starttime(t1), window_end=Seis.endtime(t1);
                   xcorr=true,
                   nphi=SPLIT_NPHI, ndt=SPLIT_NDT, dt_max=SPLIT_DT_MAX) where {T,V}
    t1, t2 = check_trace_order(t1, t2) # t2 is now clockwise of t1
    n, e = Seis.rotate_through(t1, t2, -t1.sta.azi)
    Seis.cut!.((n, e), window_start, window_end)
    phi = range(-90., stop=90., length=nphi)
    dt = range(0.0, stop=dt_max, length=ndt)
    lam1, lam2 = zeros(T, nphi, ndt), zeros(T, nphi, ndt)
    N, E = deepcopy(n), deepcopy(e)
    @inbounds for j in eachindex(dt)
        # Only need to compute zero-δt once
        if j == firstindex(dt)
            lam1₀, lam2₀ = compute_eigvals(n, e, zero(first(phi)), dt[j], N, E)
            lam1[:,j] .= lam1₀
            lam2[:,j] .= lam2₀
            continue
        end
        for i in eachindex(phi)
            lam1[i,j], lam2[i,j] = compute_eigvals(n, e, phi[i], dt[j], N, E)
        end
    end
    # Best parameters
    ip, idt = minloc2(lam2)
    phi_best = phi[ip]
    dt_best = dt[idt]
    # Find source polarisation and error therein
    spol, dspol = sourcepol(n, e, phi[ip], dt[idt])
    # Errors in splitting parameters
    dphi, ddt, ν = errors_scale_lam2!(lam2, N, E, n, e, phi_best, dt_best, spol, phi, dt)

    # Rotation correlation if desired
    xc_time, xc_phi, xc_map, xc_phi_best, xc_dt_best = if xcorr
        phi_xcorr = range(-90, 90, length=nphi÷2+1)[1:end-1]
        _rotation_correlation!(n, e, phi_xcorr, dt_max)
    else
        nothing, nothing, nothing, nothing, nothing
    end

    # Return result
    Result(phi, dt, lam1, lam2, phi_best, dphi, dt_best, ddt, spol, dspol, t1, t2,
           window_start, window_end, ν,
           # rotation correlation parameters
           xc_phi, xc_time, xc_map, xc_phi_best, xc_dt_best)
end

"""
    compute_eigvals(t1, t2, phi, dt, T1, T2) -> λ₁, λ₂

Compute the two eigenvalues for traces for a specific fast orientation, `phi`°,
and delay time, `dt` s.  `t1` and `t2` are assumed to be orthogonal, and `T1`
and `T2` are a pair of temporary storage traces matching `t1` and `t2`, respectively.
"""
function compute_eigvals(t1::Seis.Trace, t2::Seis.Trace, phi::Number, dt::Number,
                         T1::Seis.Trace, T2::Seis.Trace)
    # Note that we swap the delay time, because we are applying the inverse
    # splitting operator.
    copy_trace!(T1, t1)
    copy_trace!(T2, t2)
    apply_split!(T1, T2, phi, -dt)
    c = covar(T1, T2)
    eval = eigvals(c)
    maximum(eval), minimum(eval)
end

"""
    sourcepol(t1, t2, phi, dt) -> spol, dspol

Compute the source polarisation `spol` and error `dspol` for the pair of traces `t1`
and `t2` for the best-fitting splitting parameters `phi`° and `dt` s.
"""
function sourcepol(t1, t2, phi::Number, dt::Number)
    T1, T2 = deepcopy(t1), deepcopy(t2)
    apply_split!(T1, T2, phi, -dt)
    c = covar(T1, T2)
    eval, evec = eigen(c)
    i1 = argmax(eval)
    i2 = 3 - i1
    lam1 = eval[i1]
    lam2 = eval[i2]
    spol = mod(rad2deg(atan(evec[2,i1], evec[1,i1])), 180)
    dspol = rad2deg(atan(lam2/lam1))
    spol, dspol
end

"""
    covar(t1, t2) -> c

Return the covariance matrix `c` for two traces.
"""
function covar(t1::Seis.Trace{T,V,S}, t2::Seis.Trace{T,V,S}) where {T,V,S}
    c11 = c22 = c12 = zero(eltype(V))
    @inbounds for i in 1:Seis.nsamples(t1)
        c11 += t1.t[i]^2
        c22 += t2.t[i]^2
        c12 += t1.t[i]*t2.t[i]
    end
    c = SArray{Tuple{2,2},T}(c11, c12, c12, c22)
    c
end

"""
    errors_scale_lam2!(lam2, N, E, n, e, phi_best, dt_best, spol, phi, dt) -> σϕ, σδt, ν

Return the 1σ errors in ϕ and δt, `σϕ` and `σδt` plus the number of degrees of freedom
`ν`, for the best-fitting splitting parameters
`phi_best` and `dt_best`, and scale the λ₂ surface, `lam2`, such that the 95% confidence contour
has a value of 1.  `spol` is the retrieved source polarisation.
`n` and `e` are the north and east input traces, and `N` and `E` are
temporary traces which will be rotated to the fast-slow direction to compute
the errors.  `phi` and `dt` are the values of ϕ and δt along the axes of `lam2`.
"""
function errors_scale_lam2!(lam2, N, E, n, e, phi_best, dt_best, spol, phi, dt)
    copy_trace!(N, n)
    copy_trace!(E, e)
    # Rotate to fast-slow and remove splitting
    rotate_traces!(N, E, -phi_best)
    shift_trace!(N, dt_best)
    # Rotate to polarisation direction.  E should be ~ 0 and thus represent noise
    rotate_traces!(N, E, phi_best - spol)
    ν = degrees_of_freedom(E.t)
    if ν <= 2
        @warn("Degrees of freedom ≤ 2; resetting to 3.  σ may be inaccurate.")
        ν = 3
    end
    # Critical F-statistic at 95% F(k, ν-2) where k = 2
    Fν = Distributions.quantile(Distributions.FDist(2, ν - 2), 0.95)
    # Scale λ₂
    λ₂_min = minimum(lam2)
    if λ₂_min < eps(λ₂_min)
        @warn("Minimum λ₂ is zero (can occur in synthetics).  " *
              "Normalising by non-zero value.  σ may be inaccurate.")
        λ₂_min = √eps(λ₂_min)
    end
    # Normalise 95% contour to 1
    lam2 .= lam2./(1 + 2Fν/(ν - 2))./λ₂_min
    # Get errors by scanning the error surface
    σ_ϕ, σ_δt = errors_from_normalised_lam2(lam2, phi, dt)
    σ_ϕ, σ_δt, ν
end

"""
    degrees_of_freedom(f) -> ndf

Return an estimation of the degrees of freedom in the noise vector `f`.
"""
function degrees_of_freedom(f)
    # Compute amplitude spectrum
    F = abs.(FFTW.rfft(f))
    E₂ = sum(x->x^2, F)
    E₂ -= (F[1]^2 + F[end]^2)/2
    E₄ = 1/3*(F[1]^4 + F[end]^4)
    for i in 2:(length(F)-1)
        E₄ += 4/3*F[i]^4
    end
    ndf = round(Int, 4E₂^2/E₄ - 2)
end

"""
    errors_from_normalised_lam2(lam2, phi, dt) -> σ_ϕ, σ_δt

Compute the 1σ uncertainties in ϕ and δt for the normalised λ₂ surface `lam2`,
given the values of ϕ `phi` and δt `dt` along the axes of `lam2`.
"""
function errors_from_normalised_lam2(lam2, phi, dt)
    I = findall(x->x<=1, lam2)
    idt1 = minimum(x->x[2], I)
    idt2 = maximum(x->x[2], I)
    σ_δt = max((idt2 - idt1)*step(dt)/4, step(dt)/4)
    nphi = length(unique(getindex.(I, 1)))
    σ_ϕ = max(nphi*step(phi)/4, step(phi)/4)
    σ_ϕ, σ_δt
end
