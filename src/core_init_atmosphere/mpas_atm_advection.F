! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html
!
module atm_advection

   use mpas_kind_types
   use mpas_derived_types
   use mpas_pool_routines
   use mpas_constants
   use mpas_abort, only : mpas_dmpar_global_abort
   use mpas_log, only : mpas_log_write


   contains


   subroutine atm_initialize_advection_rk( mesh, nCells, nEdges, maxEdges, on_a_sphere, sphere_radius )
                                      
!
! compute the cell coefficients for the polynomial fit.
! this is performed during setup for model integration.
! WCS, 31 August 2009
!
      implicit none

      type (mpas_pool_type), intent(inout) :: mesh
      integer, intent(in) :: nCells, nEdges, maxEdges
      logical, intent(in) :: on_a_sphere
      real (kind=RKIND), intent(in) :: sphere_radius

      real (kind=RKIND), dimension(:,:,:), pointer :: deriv_two
      real (kind=RKIND), dimension(:), pointer :: xCell, yCell, zCell
      real (kind=RKIND), dimension(:), pointer :: xVertex, yVertex, zVertex
      real (kind=RKIND), dimension(:), pointer :: angleEdge, dcEdge
      integer, dimension(:,:), pointer :: advCells
      integer, dimension(:), pointer :: nEdgesOnCell
      integer, dimension(:,:), pointer :: cellsOnCell, edgesOnCell, verticesOnEdge, cellsOnEdge

!  local variables

      real (kind=RKIND), dimension(2,nEdges) :: thetae
      real (kind=RKIND), dimension(nCells) :: theta_abs

      real (kind=RKIND), dimension(25) :: xc, yc, zc ! cell center coordinates
      real (kind=RKIND), dimension(25) :: thetav, thetat, dl_sphere
      real (kind=RKIND) :: xec, yec, zec
      real (kind=RKIND) :: thetae_tmp
      real (kind=RKIND) :: xv1, xv2, yv1, yv2, zv1, zv2
      integer :: i, j, k, ip1, ip2, n
      integer :: iCell, iEdge
      real (kind=RKIND) :: pii
      real (kind=RKIND), dimension(25) :: xp, yp
      
      real (kind=RKIND) :: amatrix(25,25), bmatrix(25,25), wmatrix(25,25)
      real (kind=RKIND) :: length_scale
      integer :: ma,na, cell_add, mw
      integer, dimension(25) :: cell_list
      logical :: add_the_cell, do_the_cell

      real (kind=RKIND) :: cos2t, costsint, sin2t
      real (kind=RKIND), dimension(maxEdges) :: angle_2d

      integer, parameter :: polynomial_order = 2
      logical, parameter :: least_squares = .true.
      logical, parameter :: reset_poly = .true.


      pii = 2.*asin(1.0)

      call mpas_pool_get_array(mesh, 'advCells', advCells)
      call mpas_pool_get_array(mesh, 'deriv_two', deriv_two)
      call mpas_pool_get_array(mesh, 'nEdgesOnCell', nEdgesOnCell)
      call mpas_pool_get_array(mesh, 'edgesOnCell', edgesOnCell)
      call mpas_pool_get_array(mesh, 'verticesOnEdge', verticesOnEdge)
      call mpas_pool_get_array(mesh, 'cellsOnEdge', cellsOnEdge)
      call mpas_pool_get_array(mesh, 'cellsOnCell', cellsOnCell)
      call mpas_pool_get_array(mesh, 'xCell', xCell)
      call mpas_pool_get_array(mesh, 'yCell', yCell)
      call mpas_pool_get_array(mesh, 'zCell', zCell)
      call mpas_pool_get_array(mesh, 'xVertex', xVertex)
      call mpas_pool_get_array(mesh, 'yVertex', yVertex)
      call mpas_pool_get_array(mesh, 'zVertex', zVertex)
      call mpas_pool_get_array(mesh, 'angleEdge', angleEdge)
      call mpas_pool_get_array(mesh, 'dcEdge', dcEdge)

      deriv_two(:,:,:) = 0.

      do iCell = 1, nCells !  is this correct? - we need first halo cell also...

         cell_list(1) = iCell
         do i=2,nEdgesOnCell(iCell)+1
            cell_list(i) = cellsOnCell(i-1,iCell)
         end do
         n = nEdgesOnCell(iCell) + 1

         if ( polynomial_order > 2 ) then
            do i=2,nEdgesOnCell(iCell) + 1
               do j=1,nEdgesOnCell( cell_list(i) )
                  cell_add = cellsOnCell(j,cell_list(i))
                  add_the_cell = .true.
                  do k=1,n
                     if ( cell_add == cell_list(k) ) add_the_cell = .false.
                  end do
                  if (add_the_cell) then
                     n = n+1
                     cell_list(n) = cell_add
                  end if
               end do
            end do
         end if
 
         advCells(1,iCell) = n

!  check to see if we are reaching outside the halo

         do_the_cell = .true.
         do i=1,n
            if (cell_list(i) > nCells) do_the_cell = .false.
         end do


         if ( .not. do_the_cell ) cycle


!  compute poynomial fit for this cell if all needed neighbors exist
         if ( on_a_sphere ) then

            do i=1,n
               advCells(i+1,iCell) = cell_list(i)
               xc(i) = xCell(advCells(i+1,iCell))/sphere_radius
               yc(i) = yCell(advCells(i+1,iCell))/sphere_radius
               zc(i) = zCell(advCells(i+1,iCell))/sphere_radius
            end do

            !
            ! In case the current cell center lies at exactly z=1.0, the sphere_angle() routine
            !    may generate an FPE since the triangle it is given will have a zero side length
            !    adjacent to the vertex whose angle we are trying to find; in this case, simply
            !    set the value of theta_abs directly
            !
            if (zc(1) == 1.0) then
               theta_abs(iCell) = pii/2.
            else
               theta_abs(iCell) =  pii/2. - sphere_angle( xc(1), yc(1), zc(1),  &
                                                          xc(2), yc(2), zc(2),  &
                                                          0.0_RKIND, 0.0_RKIND, 1.0_RKIND ) 
            end if
  
! angles from cell center to neighbor centers (thetav)

            do i=1,n-1
   
               ip2 = i+2
               if (ip2 > n) ip2 = 2
    
               thetav(i) = sphere_angle( xc(1),   yc(1),   zc(1),    &
                                         xc(i+1), yc(i+1), zc(i+1),  &
                                         xc(ip2), yc(ip2), zc(ip2)   )
  
               dl_sphere(i) = sphere_radius*arc_length( xc(1),   yc(1),   zc(1),  &
                                                             xc(i+1), yc(i+1), zc(i+1) )
            end do

            length_scale = 1.
            do i=1,n-1
               dl_sphere(i) = dl_sphere(i)/length_scale
            end do

!            thetat(1) = 0.  !  this defines the x direction, cell center 1 -> 
            thetat(1) = theta_abs(iCell)  !  this defines the x direction, longitude line
            do i=2,n-1
               thetat(i) = thetat(i-1) + thetav(i-1)
            end do
   
            do i=1,n-1
               xp(i) = cos(thetat(i)) * dl_sphere(i)
               yp(i) = sin(thetat(i)) * dl_sphere(i)
            end do

         else     ! On an x-y plane

            do i=1,n-1

               angle_2d(i) = angleEdge(edgesOnCell(i,iCell))
               iEdge = edgesOnCell(i,iCell)
               if ( iCell /= cellsOnEdge(1,iEdge)) &
                  angle_2d(i) = angle_2d(i) - pii
  
!                 xp(i) = xCell(cell_list(i)) - xCell(iCell)
!                 yp(i) = yCell(cell_list(i)) - yCell(iCell)

               xp(i) = dcEdge(edgesOnCell(i,iCell)) * cos(angle_2d(i))
               yp(i) = dcEdge(edgesOnCell(i,iCell)) * sin(angle_2d(i))

            end do

         end if


         ma = n-1
         mw = nEdgesOnCell(iCell)

         bmatrix = 0.
         amatrix = 0.
         wmatrix = 0.

         if (polynomial_order == 2) then
            na = 6
            ma = ma+1
  
            amatrix(1,1) = 1.
            wmatrix(1,1) = 1.
            do i=2,ma
               amatrix(i,1) = 1.
               amatrix(i,2) = xp(i-1)
               amatrix(i,3) = yp(i-1)
               amatrix(i,4) = xp(i-1)**2
               amatrix(i,5) = xp(i-1) * yp(i-1)
               amatrix(i,6) = yp(i-1)**2
   
               wmatrix(i,i) = 1.
            end do
 
         else if (polynomial_order == 3) then
            na = 10
            ma = ma+1
  
            amatrix(1,1) = 1.
            wmatrix(1,1) = 1.
            do i=2,ma
               amatrix(i,1) = 1.
               amatrix(i,2) = xp(i-1)
               amatrix(i,3) = yp(i-1)
     
               amatrix(i,4) = xp(i-1)**2
               amatrix(i,5) = xp(i-1) * yp(i-1)
               amatrix(i,6) = yp(i-1)**2
     
               amatrix(i,7) = xp(i-1)**3
               amatrix(i,8) = yp(i-1) * (xp(i-1)**2)
               amatrix(i,9) = xp(i-1) * (yp(i-1)**2)
               amatrix(i,10) = yp(i-1)**3
     
               wmatrix(i,i) = 1.
   
            end do
  
         else
            na = 15
            ma = ma+1
  
            amatrix(1,1) = 1.
            wmatrix(1,1) = 1.
            do i=2,ma
               amatrix(i,1) = 1.
               amatrix(i,2) = xp(i-1)
               amatrix(i,3) = yp(i-1)
     
               amatrix(i,4) = xp(i-1)**2
               amatrix(i,5) = xp(i-1) * yp(i-1)
               amatrix(i,6) = yp(i-1)**2
     
               amatrix(i,7) = xp(i-1)**3
               amatrix(i,8) = yp(i-1) * (xp(i-1)**2)
               amatrix(i,9) = xp(i-1) * (yp(i-1)**2)
               amatrix(i,10) = yp(i-1)**3
     
               amatrix(i,11) = xp(i-1)**4
               amatrix(i,12) = yp(i-1) * (xp(i-1)**3)
               amatrix(i,13) = (xp(i-1)**2)*(yp(i-1)**2)
               amatrix(i,14) = xp(i-1) * (yp(i-1)**3)
               amatrix(i,15) = yp(i-1)**4
   
               wmatrix(i,i) = 1.
  
            end do
   
            do i=1,mw
               wmatrix(i,i) = 1.
            end do
   
         end if
 
         call poly_fit_2( amatrix, bmatrix, wmatrix, ma, na, 25 )

         do i=1,nEdgesOnCell(iCell)
            ip1 = i+1
            if (ip1 > n-1) ip1 = 1
  
            iEdge = edgesOnCell(i,iCell)
            xv1 = xVertex(verticesOnEdge(1,iedge))/sphere_radius
            yv1 = yVertex(verticesOnEdge(1,iedge))/sphere_radius
            zv1 = zVertex(verticesOnEdge(1,iedge))/sphere_radius
            xv2 = xVertex(verticesOnEdge(2,iedge))/sphere_radius
            yv2 = yVertex(verticesOnEdge(2,iedge))/sphere_radius
            zv2 = zVertex(verticesOnEdge(2,iedge))/sphere_radius
  
            if ( on_a_sphere ) then
               call arc_bisect( xv1, yv1, zv1,  &
                                xv2, yv2, zv2,  &
                                xec, yec, zec   )
  
               thetae_tmp = sphere_angle( xc(1),   yc(1),   zc(1),    &
                                          xc(i+1), yc(i+1), zc(i+1),  &
                                          xec,     yec,     zec       )
               thetae_tmp = thetae_tmp + thetat(i)
               if (iCell == cellsOnEdge(1,iEdge)) then
                  thetae(1,edgesOnCell(i,iCell)) = thetae_tmp
               else
                  thetae(2,edgesOnCell(i,iCell)) = thetae_tmp
               end if
!            else
!
!               xe(edgesOnCell(i,iCell)) = 0.5 * (xv1 + xv2)
!               ye(edgesOnCell(i,iCell)) = 0.5 * (yv1 + yv2)

            end if
  
         end do

!  fill second derivative stencil for rk advection 

         do i=1, nEdgesOnCell(iCell)
            iEdge = edgesOnCell(i,iCell)
  
  
            if ( on_a_sphere ) then
               if (iCell == cellsOnEdge(1,iEdge)) then
  
                  cos2t = cos(thetae(1,edgesOnCell(i,iCell)))
                  sin2t = sin(thetae(1,edgesOnCell(i,iCell)))
                  costsint = cos2t*sin2t
                  cos2t = cos2t**2
                  sin2t = sin2t**2
   
                  do j=1,n
                     deriv_two(j,1,iEdge) =   2.*cos2t*bmatrix(4,j)  &
                                            + 2.*costsint*bmatrix(5,j)  &
                                            + 2.*sin2t*bmatrix(6,j)
                  end do
               else
     
                  cos2t = cos(thetae(2,edgesOnCell(i,iCell)))
                  sin2t = sin(thetae(2,edgesOnCell(i,iCell)))
                  costsint = cos2t*sin2t
                  cos2t = cos2t**2
                  sin2t = sin2t**2
      
                  do j=1,n
                     deriv_two(j,2,iEdge) =   2.*cos2t*bmatrix(4,j)  &
                                            + 2.*costsint*bmatrix(5,j)  &
                                            + 2.*sin2t*bmatrix(6,j)
                  end do
               end if

            else

               cos2t = cos(angle_2d(i))
               sin2t = sin(angle_2d(i))
               costsint = cos2t*sin2t
               cos2t = cos2t**2
               sin2t = sin2t**2

!               do j=1,n
!
!                  deriv_two(j,1,iEdge) =   2.*xe(iEdge)*xe(iEdge)*bmatrix(4,j)  &
!                                         + 2.*xe(iEdge)*ye(iEdge)*bmatrix(5,j)  &
!                                         + 2.*ye(iEdge)*ye(iEdge)*bmatrix(6,j)
!               end do

               if (iCell == cellsOnEdge(1,iEdge)) then
                  do j=1,n
                     deriv_two(j,1,iEdge) =   2.*cos2t*bmatrix(4,j)  &
                                            + 2.*costsint*bmatrix(5,j)  &
                                            + 2.*sin2t*bmatrix(6,j)
                  end do
               else
                  do j=1,n
                     deriv_two(j,2,iEdge) =   2.*cos2t*bmatrix(4,j)  &
                                            + 2.*costsint*bmatrix(5,j)  &
                                            + 2.*sin2t*bmatrix(6,j)
                  end do
               end if

            end if
         end do
 
      end do ! end of loop over cells

   end subroutine atm_initialize_advection_rk


   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! FUNCTION SPHERE_ANGLE
   !
   ! Computes the angle between arcs AB and AC, given points A, B, and C
   ! Equation numbers w.r.t. http://mathworld.wolfram.com/SphericalTrigonometry.html
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   real (kind=RKIND) function sphere_angle(ax, ay, az, bx, by, bz, cx, cy, cz)
   
      implicit none
   
      real (kind=RKIND), intent(in) :: ax, ay, az, bx, by, bz, cx, cy, cz
   
      real (kind=RKIND) :: a, b, c          ! Side lengths of spherical triangle ABC
   
      real (kind=RKIND) :: ABx, ABy, ABz    ! The components of the vector AB
      real (kind=RKIND) :: ACx, ACy, ACz    ! The components of the vector AC
   
      real (kind=RKIND) :: Dx               ! The i-components of the cross product AB x AC
      real (kind=RKIND) :: Dy               ! The j-components of the cross product AB x AC
      real (kind=RKIND) :: Dz               ! The k-components of the cross product AB x AC
   
      real (kind=RKIND) :: s                ! Semiperimeter of the triangle
      real (kind=RKIND) :: sin_angle
   
      a = arc_length(bx, by, bz, cx, cy, cz)
      b = arc_length(ax, ay, az, cx, cy, cz)
      c = arc_length(ax, ay, az, bx, by, bz)
   
      ABx = bx - ax
      ABy = by - ay
      ABz = bz - az
   
      ACx = cx - ax
      ACy = cy - ay
      ACz = cz - az
   
      Dx =   (ABy * ACz) - (ABz * ACy)
      Dy = -((ABx * ACz) - (ABz * ACx))
      Dz =   (ABx * ACy) - (ABy * ACx)
   
      s = 0.5*(a + b + c)
!      sin_angle = sqrt((sin(s-b)*sin(s-c))/(sin(b)*sin(c)))   ! Eqn. (28)
      sin_angle = sqrt(min(1.0_RKIND,max(0.0_RKIND,(sin(s-b)*sin(s-c))/(sin(b)*sin(c)))))   ! Eqn. (28)
   
      if ((Dx*ax + Dy*ay + Dz*az) >= 0.0) then
         sphere_angle =  2.0 * asin(max(min(sin_angle,1.0_RKIND),-1.0_RKIND))
      else
         sphere_angle = -2.0 * asin(max(min(sin_angle,1.0_RKIND),-1.0_RKIND))
      end if
   
   end function sphere_angle
   

   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! FUNCTION PLANE_ANGLE
   !
   ! Computes the angle between vectors AB and AC, given points A, B, and C, and
   !   a vector (u,v,w) normal to the plane.
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   real (kind=RKIND) function plane_angle(ax, ay, az, bx, by, bz, cx, cy, cz, u, v, w)
   
      implicit none
   
      real (kind=RKIND), intent(in) :: ax, ay, az, bx, by, bz, cx, cy, cz, u, v, w
   
      real (kind=RKIND) :: ABx, ABy, ABz    ! The components of the vector AB
      real (kind=RKIND) :: mAB              ! The magnitude of AB
      real (kind=RKIND) :: ACx, ACy, ACz    ! The components of the vector AC
      real (kind=RKIND) :: mAC              ! The magnitude of AC
   
      real (kind=RKIND) :: Dx               ! The i-components of the cross product AB x AC
      real (kind=RKIND) :: Dy               ! The j-components of the cross product AB x AC
      real (kind=RKIND) :: Dz               ! The k-components of the cross product AB x AC
   
      real (kind=RKIND) :: cos_angle
   
      ABx = bx - ax
      ABy = by - ay
      ABz = bz - az
      mAB = sqrt(ABx**2.0 + ABy**2.0 + ABz**2.0)
   
      ACx = cx - ax
      ACy = cy - ay
      ACz = cz - az
      mAC = sqrt(ACx**2.0 + ACy**2.0 + ACz**2.0)
   
   
      Dx =   (ABy * ACz) - (ABz * ACy)
      Dy = -((ABx * ACz) - (ABz * ACx))
      Dz =   (ABx * ACy) - (ABy * ACx)
   
      cos_angle = (ABx*ACx + ABy*ACy + ABz*ACz) / (mAB * mAC)
   
      if ((Dx*u + Dy*v + Dz*w) >= 0.0) then
         plane_angle =  acos(max(min(cos_angle,1.0_RKIND),-1.0_RKIND))
      else
         plane_angle = -acos(max(min(cos_angle,1.0_RKIND),-1.0_RKIND))
      end if
   
   end function plane_angle


   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! FUNCTION ARC_LENGTH
   !
   ! Returns the length of the great circle arc from A=(ax, ay, az) to 
   !    B=(bx, by, bz). It is assumed that both A and B lie on the surface of the
   !    same sphere centered at the origin.
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   real (kind=RKIND) function arc_length(ax, ay, az, bx, by, bz)
   
      implicit none
   
      real (kind=RKIND), intent(in) :: ax, ay, az, bx, by, bz
   
      real (kind=RKIND) :: r, c
      real (kind=RKIND) :: cx, cy, cz
   
      cx = bx - ax
      cy = by - ay
      cz = bz - az

!      r = ax*ax + ay*ay + az*az
!      c = cx*cx + cy*cy + cz*cz
!
!      arc_length = sqrt(r) * acos(1.0 - c/(2.0*r))

      r = sqrt(ax*ax + ay*ay + az*az)
      c = sqrt(cx*cx + cy*cy + cz*cz)
!      arc_length = sqrt(r) * 2.0 * asin(c/(2.0*r))
      arc_length = r * 2.0 * asin(c/(2.0*r))

   end function arc_length
   
   
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE ARC_BISECT
   !
   ! Returns the point C=(cx, cy, cz) that bisects the great circle arc from
   !   A=(ax, ay, az) to B=(bx, by, bz). It is assumed that A and B lie on the
   !   surface of a sphere centered at the origin.
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   subroutine arc_bisect(ax, ay, az, bx, by, bz, cx, cy, cz)
   
      implicit none
   
      real (kind=RKIND), intent(in) :: ax, ay, az, bx, by, bz
      real (kind=RKIND), intent(out) :: cx, cy, cz
   
      real (kind=RKIND) :: r           ! Radius of the sphere
      real (kind=RKIND) :: d           
   
      r = sqrt(ax*ax + ay*ay + az*az)
   
      cx = 0.5*(ax + bx)
      cy = 0.5*(ay + by)
      cz = 0.5*(az + bz)
   
      if (cx == 0. .and. cy == 0. .and. cz == 0.) then
         call mpas_log_write('arc_bisect: A and B are diametrically opposite', messageType=MPAS_LOG_CRIT)
      else
         d = sqrt(cx*cx + cy*cy + cz*cz)
         cx = r * cx / d
         cy = r * cy / d
         cz = r * cz / d
      end if
   
   end subroutine arc_bisect


   subroutine poly_fit_2(a_in,b_out,weights_in,m,n,ne)

      implicit none

      integer, intent(in) :: m,n,ne
      real (kind=RKIND), dimension(ne,ne), intent(in) :: a_in, weights_in
      real (kind=RKIND), dimension(ne,ne), intent(out) :: b_out
   
      ! local storage
   
      real (kind=RKIND), dimension(m,n)  :: a
      real (kind=RKIND), dimension(n,m)  :: b
      real (kind=RKIND), dimension(m,m)  :: w,wt,h
      real (kind=RKIND), dimension(n,m)  :: at, ath
      real (kind=RKIND), dimension(n,n)  :: ata, atha, atha_inv
!      real (kind=RKIND), dimension(n,n)  :: ata_inv
      integer, dimension(n) :: indx
   
      if ( (ne < n) .or. (ne < m) ) then
         call mpas_log_write('poly_fit_2: inversion $i $i $i', messageType=MPAS_LOG_CRIT, intArgs=(/m,n,ne/))
      end if
   
      a(1:m,1:n) = a_in(1:m,1:n)
      w(1:m,1:m) = weights_in(1:m,1:m) 
      b_out(:,:) = 0.   

      wt = transpose(w)
      h = matmul(wt,w)
      at = transpose(a)
      ath = matmul(at,h)
      atha = matmul(ath,a)
      
      ata = matmul(at,a)

!      if (m == n) then
!         call migs(a,n,b,indx)
!      else

         call migs(atha,n,atha_inv,indx)

         b = matmul(atha_inv,ath)

!         call migs(ata,n,ata_inv,indx)
!         b = matmul(ata_inv,at)
!      end if
      b_out(1:n,1:m) = b(1:n,1:m)

   end subroutine poly_fit_2


   ! Updated 10/24/2001.
   !
   !!!!!!!!!!!!!!!!!!!!!!!!!!!   Program 4.4   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   !
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   !                                                                       !
   ! Please Note:                                                          !
   !                                                                       !
   ! (1) This computer program is written by Tao Pang in conjunction with  !
   !     his book, "An Introduction to Computational Physics," published   !
   !     by Cambridge University Press in 1997.                            !
   !                                                                       !
   ! (2) No warranties, express or implied, are made for this program.     !
   !                                                                       !
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   !
   SUBROUTINE MIGS (A,N,X,INDX)
   !
   ! Subroutine to invert matrix A(N,N) with the inverse stored
   ! in X(N,N) in the output.  Copyright (c) Tao Pang 2001.
   !
     IMPLICIT NONE
     INTEGER, INTENT (IN) :: N
     INTEGER :: I,J,K
     INTEGER, INTENT (OUT), DIMENSION (N) :: INDX
     REAL (kind=RKIND), INTENT (INOUT), DIMENSION (N,N):: A
     REAL (kind=RKIND), INTENT (OUT), DIMENSION (N,N):: X
     REAL (kind=RKIND), DIMENSION (N,N) :: B
   !
     DO I = 1, N
       DO J = 1, N
         B(I,J) = 0.0
       END DO
     END DO
     DO I = 1, N
       B(I,I) = 1.0
     END DO
   !
     CALL ELGS (A,N,INDX)
   !
     DO I = 1, N-1
       DO J = I+1, N
         DO K = 1, N
           B(INDX(J),K) = B(INDX(J),K)-A(INDX(J),I)*B(INDX(I),K)
         END DO
       END DO
     END DO
   !
     DO I = 1, N
       X(N,I) = B(INDX(N),I)/A(INDX(N),N)
       DO J = N-1, 1, -1
         X(J,I) = B(INDX(J),I)
         DO K = J+1, N
           X(J,I) = X(J,I)-A(INDX(J),K)*X(K,I)
         END DO
         X(J,I) =  X(J,I)/A(INDX(J),J)
       END DO
     END DO
   END SUBROUTINE MIGS


   SUBROUTINE ELGS (A,N,INDX)
   !
   ! Subroutine to perform the partial-pivoting Gaussian elimination.
   ! A(N,N) is the original matrix in the input and transformed matrix
   ! plus the pivoting element ratios below the diagonal in the output.
   ! INDX(N) records the pivoting order.  Copyright (c) Tao Pang 2001.
   !
     IMPLICIT NONE
     INTEGER, INTENT (IN) :: N
     INTEGER :: I,J,K,ITMP
     INTEGER, INTENT (OUT), DIMENSION (N) :: INDX
     REAL (kind=RKIND) :: C1,PI,PI1,PJ
     REAL (kind=RKIND), INTENT (INOUT), DIMENSION (N,N) :: A
     REAL (kind=RKIND), DIMENSION (N) :: C
   !
   ! Initialize the index
   !
     DO I = 1, N
       INDX(I) = I
     END DO
   !
   ! Find the rescaling factors, one from each row
   !
     DO I = 1, N
       C1= 0.0
       DO J = 1, N
         C1 = MAX(C1,ABS(A(I,J)))
       END DO
       C(I) = C1
     END DO
   !
   ! Search the pivoting (largest) element from each column
   !
     DO J = 1, N-1
       PI1 = 0.0
       DO I = J, N
         PI = ABS(A(INDX(I),J))/C(INDX(I))
         IF (PI.GT.PI1) THEN
           PI1 = PI
           K   = I
         ENDIF
       END DO
   !
   ! Interchange the rows via INDX(N) to record pivoting order
   !
       ITMP    = INDX(J)
       INDX(J) = INDX(K)
       INDX(K) = ITMP
       DO I = J+1, N
         PJ  = A(INDX(I),J)/A(INDX(J),J)
   !
   ! Record pivoting ratios below the diagonal
   !
         A(INDX(I),J) = PJ
   !
   ! Modify other elements accordingly
   !
         DO K = J+1, N
           A(INDX(I),K) = A(INDX(I),K)-PJ*A(INDX(J),K)
         END DO
       END DO
     END DO
   !
   END SUBROUTINE ELGS
   

   subroutine atm_initialize_deformation_weights( mesh, nCells, on_a_sphere, sphere_radius )
                                      
!
! compute the cell coefficients for the deformation calculations
! WCS, 13 July 2010
!
      implicit none

      type (mpas_pool_type), intent(inout) :: mesh
      integer, intent(in) :: nCells
      logical, intent(in) :: on_a_sphere
      real (kind=RKIND), intent(in) :: sphere_radius

!  local variables

      real (kind=RKIND), dimension(:,:), pointer :: defc_a, defc_b
      real (kind=RKIND), dimension(:,:), pointer :: cell_gradient_coef_x, cell_gradient_coef_y
      integer, dimension(:,:), pointer :: cellsOnEdge, edgesOnCell, cellsOnCell, verticesOnCell
      integer, dimension(:), pointer :: nEdgesOnCell
      real (kind=RKIND), dimension(:), pointer :: xCell, yCell, zCell
      real (kind=RKIND), dimension(:), pointer :: xVertex, yVertex, zVertex

      real (kind=RKIND), dimension(nCells) :: theta_abs

      real (kind=RKIND), dimension(25) :: xc, yc, zc ! cell center coordinates
      real (kind=RKIND), dimension(25) :: thetav, thetat, dl_sphere
      real (kind=RKIND) :: dl
      integer :: i, ip1, ip2, n
      integer :: iCell
      real (kind=RKIND) :: pii
      real (kind=RKIND), dimension(25) :: xp, yp
      
      real (kind=RKIND) :: length_scale
      integer, dimension(25) :: cell_list

      integer :: iv
      logical :: do_the_cell
      real (kind=RKIND) :: area_cell, sint2, cost2, sint_cost, dx, dy


      call mpas_pool_get_array(mesh, 'defc_a', defc_a)
      call mpas_pool_get_array(mesh, 'defc_b', defc_b)
      call mpas_pool_get_array(mesh, 'cell_gradient_coef_x', cell_gradient_coef_x)
      call mpas_pool_get_array(mesh, 'cell_gradient_coef_y', cell_gradient_coef_y)
      call mpas_pool_get_array(mesh, 'nEdgesOnCell', nEdgesOnCell)
      call mpas_pool_get_array(mesh, 'cellsOnEdge', cellsOnEdge)
      call mpas_pool_get_array(mesh, 'edgesOnCell', edgesOnCell)
      call mpas_pool_get_array(mesh, 'cellsOnCell', cellsOnCell)
      call mpas_pool_get_array(mesh, 'verticesOnCell', verticesOnCell)
      call mpas_pool_get_array(mesh, 'xCell', xCell)
      call mpas_pool_get_array(mesh, 'yCell', yCell)
      call mpas_pool_get_array(mesh, 'zCell', zCell)
      call mpas_pool_get_array(mesh, 'xVertex', xVertex)
      call mpas_pool_get_array(mesh, 'yVertex', yVertex)
      call mpas_pool_get_array(mesh, 'zVertex', zVertex)

      defc_a(:,:) = 0.
      defc_b(:,:) = 0.

      cell_gradient_coef_x(:,:) = 0.
      cell_gradient_coef_y(:,:) = 0.

      pii = 2.*asin(1.0)

      do iCell = 1, nCells

         cell_list(1) = iCell
         do i=2,nEdgesOnCell(iCell)+1
            cell_list(i) = cellsOnCell(i-1,iCell)
         end do
         n = nEdgesOnCell(iCell) + 1

!  check to see if we are reaching outside the halo

         do_the_cell = .true.
         do i=1,n
            if (cell_list(i) > nCells) do_the_cell = .false.
         end do


         if (.not. do_the_cell) cycle

         !  compute poynomial fit for this cell if all needed neighbors exist

         if (on_a_sphere) then

            ! xc holds the center point and the vertex points of the cell,
            ! normalized to a sphere or radius 1.

            xc(1) = xCell(iCell)/sphere_radius
            yc(1) = yCell(iCell)/sphere_radius
            zc(1) = zCell(iCell)/sphere_radius

            do i=2,n
               iv = verticesOnCell(i-1,iCell)
               xc(i) = xVertex(iv)/sphere_radius
               yc(i) = yVertex(iv)/sphere_radius
               zc(i) = zVertex(iv)/sphere_radius
            end do

            !
            ! In case the current cell center lies at exactly z=1.0, the sphere_angle() routine
            !    may generate an FPE since the triangle it is given will have a zero side length
            !    adjacent to the vertex whose angle we are trying to find; in this case, simply
            !    set the value of theta_abs directly
            !
            if (zc(1) == 1.0) then
               theta_abs(iCell) = pii/2.
            else
               ! theta_abs is the angle to the first vertex from the center, normalized so that
               ! an eastward pointing vector has a angle of 0.
               theta_abs(iCell) =  pii/2. - sphere_angle( xc(1), yc(1), zc(1),  &
                                                          xc(2), yc(2), zc(2),  &
                                                          0.0_RKIND, 0.0_RKIND, 1.0_RKIND ) 
            end if

            ! here we are constructing the tangent-plane cell.
            ! thetat is the angle in the (x,y) tangent-plane coordinate from
            ! the cell center to each vertex, normalized so that an
            ! eastward pointing vector has a angle of 0.

            ! dl_sphere is the spherical distance from the cell center
            ! to the sphere vertex points for the cell.

            thetat(1) = theta_abs(iCell)
            do i=1,n-1
   
               ip2 = i+2
               if (ip2 > n) ip2 = 2
    
               thetav(i) = sphere_angle( xc(1),   yc(1),   zc(1),    &
                                         xc(i+1), yc(i+1), zc(i+1),  &
                                         xc(ip2), yc(ip2), zc(ip2)   )
               dl_sphere(i) = sphere_radius*arc_length( xc(1),   yc(1),   zc(1),  &
                                                        xc(i+1), yc(i+1), zc(i+1) )
               if(i.gt.1) thetat(i) = thetat(i-1)+thetav(i-1)
            end do

            ! xp and yp are the tangent-plane vertex points with the cell center at (0,0)

            do i=1,n-1
               xp(i) = cos(thetat(i)) * dl_sphere(i)
               yp(i) = sin(thetat(i)) * dl_sphere(i)
            end do

         else     ! On an x-y plane

            theta_abs(iCell) = 0.0

            xp(1) = xCell(iCell)
            yp(1) = yCell(iCell)

            do i=2,n
               iv = verticesOnCell(i-1,iCell)
               xp(i) = xVertex(iv)
               yp(i) = yVertex(iv)
            end do

         end if

         ! (1) compute cell area on the tangent plane used in the integrals
         ! (2) compute angle of cell edge normal vector.  here we are repurposing thetat

         area_cell = 0.
         do i=1,n-1
            ip1 = i+1
            if (ip1 == n) ip1 = 1
            dx = xp(ip1)-xp(i)
            dy = yp(ip1)-yp(i)
            area_cell = area_cell + 0.25*(xp(i)+xp(ip1))*(yp(ip1)-yp(i)) - 0.25*(yp(i)+yp(ip1))*(xp(ip1)-xp(i))
            thetat(i) = atan2(dy,dx)-pii/2.
         end do

         ! coefficients - see documentation for the formulas.

         do i=1,n-1
            ip1 = i+1
            if (ip1 == n) ip1 = 1
            dl = sqrt((xp(ip1)-xp(i))**2 + (yp(ip1)-yp(i))**2)
            sint2 = (sin(thetat(i)))**2
            cost2 = (cos(thetat(i)))**2
            sint_cost = sin(thetat(i))*cos(thetat(i))
            defc_a(i,iCell) = dl*(cost2 - sint2)/area_cell
            defc_b(i,iCell) = dl*2.*sint_cost/area_cell
            cell_gradient_coef_x(i,iCell) = dl*cos(thetat(i))/area_cell
            cell_gradient_coef_y(i,iCell) = dl*sin(thetat(i))/area_cell
            if (cellsOnEdge(1,EdgesOnCell(i,iCell)) /= iCell) then
               defc_a(i,iCell) = - defc_a(i,iCell)
               defc_b(i,iCell) = - defc_b(i,iCell)
            end if
 
         end do

      end do

   end subroutine atm_initialize_deformation_weights

 end module atm_advection
