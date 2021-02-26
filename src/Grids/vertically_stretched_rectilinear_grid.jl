"""
    VerticallyStretchedRectilinearGrid{FT, TX, TY, TZ, R, A} <: AbstractRectilinearGrid{FT, TX, TY, TZ}

A rectilinear grid with with constant horizontal grid spacings `Δx` and `Δy`, and
non-uniform or stretched vertical grid spacing `Δz` between cell centers and cell faces,
topology `{TX, TY, TZ}`, and coordinate ranges of type `R` (where a range can be used) and
`A` (where an array is needed).
"""
struct VerticallyStretchedRectilinearGrid{FT, TX, TY, TZ, R, A} <: AbstractRectilinearGrid{FT, TX, TY, TZ}

    # Number of grid points in (x,y,z).
     Nx :: Int
     Ny :: Int
     Nz :: Int

    # Halo size in (x,y,z).
     Hx :: Int
     Hy :: Int
     Hz :: Int

    # Domain size [m].
     Lx :: FT
     Ly :: FT
     Lz :: FT

    # Grid spacing [m].
     Δx :: FT
     Δy :: FT
    ΔzF :: A
    ΔzC :: A

    # Range of coordinates at the centers of the cells.
     xC :: R
     yC :: R
     zC :: A

    # Range of grid coordinates at the faces of the cells.
    # Note: there are Nx+1 faces in the x-dimension, Ny+1 in the y, and Nz+1 in the z.
     xF :: R
     yF :: R
     zF :: A
end

function VerticallyStretchedRectilinearGrid(FT=Float64; architecture = CPU(),
                                              size, x, y, zF,
                                              halo = (1, 1, 1),
                                          topology = (Periodic, Periodic, Bounded))

    TX, TY, TZ = validate_topology(topology)
    size = validate_size(TX, TY, TZ, size)
    halo = validate_halo(TX, TY, TZ, halo)
    Lx, Ly, x, y = validate_vertically_stretched_grid_xy(TX, TY, FT, x, y)

    Nx, Ny, Nz = size
    Hx, Hy, Hz = halo

    # Initialize vertically-stretched arrays on CPU
    Lz, zF, zC, ΔzF, ΔzC = generate_stretched_vertical_grid(FT, topology[3], Nz, Hz, zF)

    # Construct uniform horizontal grid
    Lh, Nh, Hh, X₁ = (Lx, Ly), size[1:2], halo[1:2], (x[1], y[1])
    Δx, Δy = Δh = Lh ./ Nh

    # Face-node limits in x, y, z
    xF₋, yF₋ = XF₋ = @. X₁ - Hh * Δh
    xF₊, yF₊ = XF₊ = @. XF₋ + total_extent(topology[1:2], Hh, Δh, Lh)

    # Center-node limits in x, y, z
    xC₋, yC₋ = XC₋ = @. XF₋ + Δh / 2
    xC₊, yC₊ = XC₊ = @. XC₋ + Lh + Δh * (2Hh - 1)

    # Total length of Center and Face quantities
    TFx, TFy, TFz = total_length.(Face, topology, size, halo)
    TCx, TCy, TCz = total_length.(Center, topology, size, halo)

    # Include halo points in coordinate arrays
    xF = range(xF₋, xF₊; length = TFx)
    yF = range(yF₋, yF₊; length = TFy)

    xC = range(xC₋, xC₊; length = TCx)
    yC = range(yC₋, yC₊; length = TCy)

    # Offset.
     xC = OffsetArray(xC,  -Hx)
     yC = OffsetArray(yC,  -Hy)
     zC = OffsetArray(zC,  -Hz)
    ΔzC = OffsetArray(ΔzC, -Hz)

     xF = OffsetArray(xF,  -Hx)
     yF = OffsetArray(yF,  -Hy)
     zF = OffsetArray(zF,  -Hz)
    ΔzF = OffsetArray(ΔzF, -Hz)

    # Needed for pressure solver solution to be divergence-free.
    # Will figure out why later...
    ΔzC[Nz] = ΔzC[Nz-1]

    # Seems needed to avoid out-of-bounds error in viscous dissipation
    # operator wanting to access ΔzC[Nz+2].
    ΔzC = OffsetArray(cat(ΔzC[0], ΔzC..., ΔzC[Nz], dims=1), -Hz-1)

    # Convert to appropriate array type for arch
     zF = OffsetArray(arch_array(architecture,  zF.parent),  zF.offsets...)
     zC = OffsetArray(arch_array(architecture,  zC.parent),  zC.offsets...)
    ΔzF = OffsetArray(arch_array(architecture, ΔzF.parent), ΔzF.offsets...)
    ΔzC = OffsetArray(arch_array(architecture, ΔzC.parent), ΔzC.offsets...)

    return VerticallyStretchedRectilinearGrid{FT, TX, TY, TZ, typeof(xF), typeof(zF)}(
        Nx, Ny, Nz, Hx, Hy, Hz, Lx, Ly, Lz, Δx, Δy, ΔzF, ΔzC, xC, yC, zC, xF, yF, zF)
end

#####
##### Vertically stretched grid utilities
#####

get_z_face(z::Function, k) = z(k)
get_z_face(z::AbstractVector, k) = z[k]

lower_exterior_ΔzF(z_topo,          zFi, Hz) = [zFi[end - Hz + k] - zFi[end - Hz + k - 1] for k = 1:Hz]
lower_exterior_ΔzF(::Type{Bounded}, zFi, Hz) = [zFi[2]  - zFi[1] for k = 1:Hz]

upper_exterior_ΔzF(z_topo,          zFi, Hz) = [zFi[k + 1] - zFi[k] for k = 1:Hz]
upper_exterior_ΔzF(::Type{Bounded}, zFi, Hz) = [zFi[end]   - zFi[end - 1] for k = 1:Hz]

function generate_stretched_vertical_grid(FT, z_topo, Nz, Hz, zF_generator)

    # Ensure correct type for zF and derived quantities
    interior_zF = zeros(FT, Nz+1)

    for k = 1:Nz+1
        interior_zF[k] = get_z_face(zF_generator, k)
    end

    Lz = interior_zF[Nz+1] - interior_zF[1]

    # Build halo regions
    ΔzF₋ = lower_exterior_ΔzF(z_topo, interior_zF, Hz)
    ΔzF₊ = upper_exterior_ΔzF(z_topo, interior_zF, Hz)

    z¹, zᴺ⁺¹ = interior_zF[1], interior_zF[Nz+1]

    zF₋ = [z¹   - sum(ΔzF₋[k:Hz]) for k = 1:Hz] # locations of faces in lower halo
    zF₊ = [zᴺ⁺¹ + ΔzF₊[k]         for k = 1:Hz] # locations of faces in width of top halo region

    zF = vcat(zF₋, interior_zF, zF₊)

    # Build cell centers, cell center spacings, and cell interface spacings
    TCz = total_length(Center, z_topo, Nz, Hz)
     zC = [ (zF[k + 1] + zF[k]) / 2 for k = 1:TCz ]
    ΔzC = [  zC[k] - zC[k - 1]      for k = 2:TCz ]

    # Trim face locations for periodic domains
    TFz = total_length(Face, z_topo, Nz, Hz)
    zF = zF[1:TFz]

    ΔzF = [zF[k + 1] - zF[k] for k = 1:TFz-1]

    return Lz, zF, zC, ΔzF, ΔzC
end

# We cannot reconstruct a VerticallyStretchedRectilinearGrid without the zF_generator.
# So the best we can do is tell the user what they should have done.
function with_halo(new_halo, old_grid::VerticallyStretchedRectilinearGrid)
    new_halo != halo_size(old_grid) &&
        @error "You need to construct your VerticallyStretchedRectilinearGrid with the keyword argument halo=$new_halo"
    return old_grid
end

short_show(grid::VerticallyStretchedRectilinearGrid{FT, TX, TY, TZ}) where {FT, TX, TY, TZ} =
    "VerticallyStretchedRectilinearGrid{$FT, $TX, $TY, $TZ}(Nx=$(grid.Nx), Ny=$(grid.Ny), Nz=$(grid.Nz))"

function show(io::IO, g::VerticallyStretchedRectilinearGrid{FT, TX, TY, TZ}) where {FT, TX, TY, TZ}
    print(io, "VerticallyStretchedRectilinearGrid{$FT, $TX, $TY, $TZ}\n",
              "                   domain: $(domain_string(g))\n",
              "                 topology: ", (TX, TY, TZ), '\n',
              "  resolution (Nx, Ny, Nz): ", (g.Nx, g.Ny, g.Nz), '\n',
              "   halo size (Hx, Hy, Hz): ", (g.Hx, g.Hy, g.Hz))
end

Adapt.adapt_structure(to, grid::VerticallyStretchedRectilinearGrid{FT, TX, TY, TZ}) where {FT, TX, TY, TZ} =
    VerticallyStretchedRectilinearGrid{FT, TX, TY, TZ, typeof(grid.xF), typeof(Adapt.adapt(to, grid.zF))}(
        grid.Nx, grid.Ny, grid.Nz,
        grid.Hx, grid.Hy, grid.Hz,
        grid.Lx, grid.Ly, grid.Lz,
        grid.Δx, grid.Δy,
        Adapt.adapt(to, grid.ΔzF),
        Adapt.adapt(to, grid.ΔzC),
        grid.xC, grid.yC,
        Adapt.adapt(to, grid.zC),
        grid.xF, grid.yF,
        Adapt.adapt(to, grid.zF))
