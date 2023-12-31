! Copyright (c) 2013,  Los Alamos National Security, LLC (LANS)
! and the University Corporation for Atmospheric Research (UCAR).
!
! Unless noted otherwise source code is licensed under the BSD license.
! Additional copyright and license information can be found in the LICENSE file
! distributed with this code, or at http://mpas-dev.github.com/license.html
!
!***********************************************************************
!
!  mpas_block_decomp
!
!> \brief   This module contains routines related to the block decomposition.
!> \author  Doug Jacobsen
!> \date    03/26/13
!> \details 
!>   This module is repsonsible for reading the decomposition files, and determining which elements should live within which blocks.
!>   It also provides interfaces to find out how blocks map to processors.
!
!-----------------------------------------------------------------------
module mpas_block_decomp

   use mpas_dmpar
   use mpas_hash
   use mpas_sort
   use mpas_derived_types
   use mpas_io_units
   use mpas_log

   type graph
      integer :: nVerticesTotal
      integer :: nVertices, maxDegree
      integer :: ghostStart
      integer, dimension(:), pointer :: vertexID
      integer, dimension(:), pointer :: nAdjacent
      integer, dimension(:,:), pointer :: adjacencyList
   end type graph

   contains

!***********************************************************************
!
!  routine mpas_block_decomp_cells_for_proc
!
!> \brief   Determines list of cells for a specific processor
!> \author  Doug Jacobsen
!> \date    03/26/13
!> \details 
!>  This routine determines a list of cells for each processor, and what blocks the live in.
!
!-----------------------------------------------------------------------
   subroutine mpas_block_decomp_cells_for_proc(dminfo, partial_global_graph_info, local_cell_list, block_id, block_start, &
                                               block_count, numBlocks, explicitProcDecomp, blockFilePrefix, procFilePrefix)!{{{

      implicit none

      type (dm_info), intent(inout) :: dminfo !< Input: domain information
      type (graph), intent(in) :: partial_global_graph_info !< Input: Global graph information
      integer, dimension(:), pointer :: local_cell_list !< Output: list of cells this processor owns, ordered by block
      integer, dimension(:), pointer :: block_id !< Output: list of global block id's this processor owns
      integer, dimension(:), pointer :: block_start !< Output: offset in local_cell_list for this blocks list of cells
      integer, dimension(:), pointer :: block_count !< Output: number of cells in blocks

      integer, intent(in) :: numBlocks !< Input: Number of blocks (from config_num_blocks)
      logical, intent(in) :: explicitProcDecomp !< Input: Logical flag controlling if blocks are explicitly assigned to processors
      character (len=*), intent(in) :: blockFilePrefix, & !< Input: File prefix for block decomposition
                                       procFilePrefix !< Input: File prefix for processor decomposition

      integer, dimension(:), pointer :: global_list
      integer, dimension(:), pointer :: global_start

      integer, dimension(:), allocatable :: local_block_list
      integer, dimension(:,:), allocatable :: sorted_local_cell_list

      integer :: i, global_block_id, local_block_id, owning_proc, iunit, istatus
      integer :: blocks_per_proc, err
      integer, dimension(:), pointer :: local_nvertices
      character (len=StrKIND) :: filename

      logical :: no_blocks

      no_blocks = .false.

      if (numBlocks == 0) then
        dminfo % total_blocks = dminfo % nProcs
      else
        dminfo % total_blocks = numBlocks
      end if

      dminfo % explicitDecomp = explicitProcDecomp

      call mpas_build_block_proc_list(dminfo, procFilePrefix)
      call mpas_get_blocks_per_proc(dminfo, dminfo % my_proc_id, blocks_per_proc)

      if(dminfo % total_blocks > 1) then
        allocate(local_nvertices(dminfo % nprocs))
        allocate(global_start(dminfo % nprocs))
        allocate(global_list(partial_global_graph_info % nVerticesTotal))

        if (dminfo % my_proc_id == IO_NODE) then

           if (dminfo % total_blocks < 10) then
              write(filename,'(a,i1)') trim(blockFilePrefix), dminfo % total_blocks
           else if (dminfo % total_blocks < 100) then
              write(filename,'(a,i2)') trim(blockFilePrefix), dminfo % total_blocks
           else if (dminfo % total_blocks < 1000) then
              write(filename,'(a,i3)') trim(blockFilePrefix), dminfo % total_blocks
           else if (dminfo % total_blocks < 10000) then
              write(filename,'(a,i4)') trim(blockFilePrefix), dminfo % total_blocks
           else if (dminfo % total_blocks < 100000) then
              write(filename,'(a,i5)') trim(blockFilePrefix), dminfo % total_blocks
           else if (dminfo % total_blocks < 1000000) then
              write(filename,'(a,i6)') trim(blockFilePrefix), dminfo % total_blocks
           else if (dminfo % total_blocks < 10000000) then
              write(filename,'(a,i7)') trim(blockFilePrefix), dminfo % total_blocks
           else if (dminfo % total_blocks < 100000000) then
              write(filename,'(a,i8)') trim(blockFilePrefix), dminfo % total_blocks
           end if

           call mpas_new_unit(iunit)
           open(unit=iunit, file=trim(filename), form='formatted', status='old', iostat=istatus)

           if (istatus /= 0) then
              call mpas_log_write('Could not open block decomposition file for $i blocks.', MPAS_LOG_ERR, intArgs=(/dminfo % total_blocks/) )
              call mpas_log_write('Filename: '//trim(filename), MPAS_LOG_CRIT)
           end if

           local_nvertices(:) = 0
           do i=1,partial_global_graph_info % nVerticesTotal
              read(unit=iunit, fmt=*, iostat=err) global_block_id

              if ( err .ne. 0 ) then
                 call mpas_log_write('Decomoposition file: ' // trim(filename) // ' contains less than $i cells', &
                                      MPAS_LOG_CRIT, intArgs=(/partial_global_graph_info % nVerticesTotal/) )
              end if
              call mpas_get_owning_proc(dminfo, global_block_id, owning_proc)
              local_nvertices(owning_proc+1) = local_nvertices(owning_proc+1) + 1
           end do

           read(unit=iunit, fmt=*, iostat=err)

           if ( err == 0 ) then
              call mpas_log_write('Decomposition file: ' // trim(filename) // ' contains more than $i cells', &
                                   MPAS_LOG_CRIT, intArgs=(/partial_global_graph_info % nVerticesTotal/) )
           end if

           global_start(1) = 1
           do i=2,dminfo % nprocs
              global_start(i) = global_start(i-1) + local_nvertices(i-1)
           end do

           rewind(unit=iunit)

           do i=1,partial_global_graph_info % nVerticesTotal
              read(unit=iunit, fmt=*, iostat=err) global_block_id
              call mpas_get_owning_proc(dminfo, global_block_id, owning_proc)
              global_list(global_start(owning_proc+1)) = i
              global_start(owning_proc+1) = global_start(owning_proc+1) + 1
           end do

           global_start(1) = 0
           do i=2,dminfo % nprocs
              global_start(i) = global_start(i-1) + local_nvertices(i-1)
           end do

           call mpas_dmpar_bcast_ints(dminfo, dminfo % nprocs, local_nvertices)
           allocate(local_cell_list(local_nvertices(dminfo % my_proc_id + 1)))
           allocate(local_block_list(local_nvertices(dminfo % my_proc_id + 1)))

           call mpas_dmpar_scatter_ints(dminfo, dminfo % nprocs, local_nvertices(dminfo % my_proc_id + 1), &
                                   global_start, local_nvertices, global_list, local_cell_list)

           ! Reset global start for second read of global_block_list
           global_start(1) = 1
           do i=2,dminfo % nprocs
              global_start(i) = global_start(i-1) + local_nvertices(i-1)
           end do

           rewind(unit=iunit)

           do i=1,partial_global_graph_info % nVerticesTotal
              read(unit=iunit, fmt=*) global_block_id
              call mpas_get_owning_proc(dminfo, global_block_id, owning_proc)
              global_list(global_start(owning_proc+1)) = global_block_id
              global_start(owning_proc+1) = global_start(owning_proc+1) + 1
           end do

           ! Recompute global start after second read of global_block_list
           global_start(1) = 0
           do i=2,dminfo % nprocs
              global_start(i) = global_start(i-1) + local_nvertices(i-1)
           end do

           call mpas_dmpar_scatter_ints(dminfo, dminfo % nprocs, local_nvertices(dminfo % my_proc_id + 1), &
                                   global_start, local_nvertices, global_list, local_block_list)

           close(unit=iunit)
           call mpas_release_unit(iunit)

        else

           call mpas_dmpar_bcast_ints(dminfo, dminfo % nprocs, local_nvertices)
           allocate(local_cell_list(local_nvertices(dminfo % my_proc_id + 1)))
           allocate(local_block_list(local_nvertices(dminfo % my_proc_id + 1)))

           call mpas_dmpar_scatter_ints(dminfo, dminfo % nprocs, local_nvertices(dminfo % my_proc_id + 1), &
                                   global_start, local_nvertices, global_list, local_cell_list)

           call mpas_dmpar_scatter_ints(dminfo, dminfo % nprocs, local_nvertices(dminfo % my_proc_id + 1), &
                                   global_start, local_nvertices, global_list, local_block_list)
        end if

        if(blocks_per_proc == 0) then
           no_blocks = .true.
           blocks_per_proc = 1
        end if

        if(no_blocks) then
           allocate(block_id(blocks_per_proc))
           allocate(block_start(blocks_per_proc))
           allocate(block_count(blocks_per_proc))

           block_id(1) = numBlocks + 1
           block_start(1) = 0
           block_count(1) = 0
        else
           allocate(sorted_local_cell_list(2, local_nvertices(dminfo % my_proc_id + 1)))
           allocate(block_id(blocks_per_proc))
           allocate(block_start(blocks_per_proc))
           allocate(block_count(blocks_per_proc))

           do i = 1, blocks_per_proc
             block_start = 0
             block_count = 0
           end do
   
           do i = 1,local_nvertices(dminfo % my_proc_id +1)
             call mpas_get_local_block_id(dminfo, local_block_list(i), local_block_id)
     
             block_id(local_block_id+1) = local_block_list(i)
     
             sorted_local_cell_list(1, i) = local_block_list(i)
             sorted_local_cell_list(2, i) = local_cell_list(i)
     
             block_count(local_block_id+1) = block_count(local_block_id+1) + 1
           end do
   
           call mpas_quicksort(local_nvertices(dminfo % my_proc_id + 1), sorted_local_cell_list)
   
           do i = 1, local_nvertices(dminfo % my_proc_id+1)
             local_cell_list(i) = sorted_local_cell_list(2, i)
           end do
   
           do i = 2,blocks_per_proc
             block_start(i) = block_start(i-1) + block_count(i-1)
           end do

           deallocate(sorted_local_cell_list)
           deallocate(local_block_list)
           deallocate(local_nvertices)
           deallocate(global_start)
           deallocate(global_list)
        end if
      else

        if (dminfo % my_proc_id == IO_NODE) then
           allocate(local_cell_list(partial_global_graph_info % nVerticesTotal))
           allocate(block_id(1))
           allocate(block_start(1))
           allocate(block_count(1))
           block_id(1) = 0
           block_start(1) = 0
           block_count(1) = size(local_cell_list)
           do i=1,size(local_cell_list)
             local_cell_list(i) = i
           end do
        else
           allocate(local_cell_list(1))
           allocate(block_id(1))
           allocate(block_start(1))
           allocate(block_count(1))
           local_cell_list(1) = 0
           block_id(1) = numBlocks + 1
           block_start(1) = 0
           block_count(1) = 0
        end if
      end if

   end subroutine mpas_block_decomp_cells_for_proc!}}}

!***********************************************************************
!
!  routine mpas_block_decomp_partitioned_edge_list
!
!> \brief   Partitions list of edges for a processor
!> \author  Doug Jacobsen
!> \date    03/26/13
!> \details 
!>  This routine partitions a list of edges for each processor, based on a list of owned cells.
!>  Output edge list has 0-Halo edges first, followed by halo edges.
!
!-----------------------------------------------------------------------
   subroutine mpas_block_decomp_partitioned_edge_list(nCells, cellIDList, maxCells, nEdges, cellsOnEdge, edgeIDList, ghostEdgeStart)!{{{

      implicit none

      integer, intent(in) :: nCells !< Input: Number of owned cells
      integer, intent(in) :: maxCells !< Input: Maximum number of cells on an edge
      integer, intent(in) :: nEdges !< Input: Number of edges
      integer, dimension(nCells), intent(in) :: cellIDList !< Input: List of owned cell IDs
      integer, dimension(maxCells, nEdges), intent(in) :: cellsOnEdge !< Input: Connectivity of cells on edges.
      integer, dimension(nEdges), intent(inout) :: edgeIDList !< Input/Output: List of edge IDs
      integer, intent(inout) :: ghostEdgeStart !< Input/Output: Index to beginning of edge halo

      integer :: i, j, lastEdge
      integer, dimension(nEdges) :: edgeIDListLocal
      type (hashtable) :: h

      call mpas_hash_init(h)

      do i=1,nCells
         ! OPTIMIZATION: Actually, if we can assume that all cellIDs are unique, the if-test is unnecessary
         if (.not. mpas_hash_search(h, cellIDList(i))) call mpas_hash_insert(h, cellIDList(i))
      end do

      lastEdge = 0
      ghostEdgeStart = nEdges+1

      edgeIDListLocal(:) = edgeIDList(:)

      do i=1,nEdges
         do j=1,maxCells
            if (cellsOnEdge(j,i) /= 0) exit
         end do
         if (j > maxCells) &
            call mpas_log_write('Error in block_decomp_partitioned_edge_list: ' // &
               'edge/vertex is not adjacent to any valid cells', MPAS_LOG_CRIT)
         if (mpas_hash_search(h, cellsOnEdge(j,i))) then
            lastEdge = lastEdge + 1
            edgeIDList(lastEdge) = edgeIDListLocal(i)
         else
            ghostEdgeStart = ghostEdgeStart - 1
            edgeIDList(ghostEdgeStart) = edgeIDListLocal(i)
         end if
         if (ghostEdgeStart <= lastEdge) then
           call mpas_log_write('block_decomp_partitioned_edge_list: ' // &
              'Somehow we have more edges than we thought we should.', MPAS_LOG_CRIT)
         end if
      end do

      if (ghostEdgeStart /= lastEdge + 1) then
         call mpas_log_write('block_decomp_partitioned_edge_list:' // &
            ' Somehow we didn''t have enough edges to fill edgeIDList.', MPAS_LOG_CRIT)
      end if

      call mpas_hash_destroy(h)

   end subroutine mpas_block_decomp_partitioned_edge_list!}}}

!***********************************************************************
!
!  routine mpas_block_decomp_all_edges_in_block
!
!> \brief   Determines all edges in a block.
!> \author  Doug Jacobsen
!> \date    03/26/13
!> \details 
!>  This routine creates a list of all edges that are in a block, based on a list of owned cells.
!
!-----------------------------------------------------------------------
   subroutine mpas_block_decomp_all_edges_in_block(maxEdges, nCells, nEdgesOnCell, edgesOnCell, nEdges, edgeList)!{{{

      implicit none

      integer, intent(in) :: maxEdges !< Input: Maximum number of edges on cell
      integer, intent(in) :: nCells !< Input: Number of owned cells
      integer, dimension(nCells), intent(in) :: nEdgesOnCell !< Input: Number of edges on each cell
      integer, dimension(maxEdges, nCells), intent(in) :: edgesOnCell !< Input: ID of edges that border each cell
      integer, intent(out) :: nEdges !< Output: Number of edges in block
      integer, dimension(:), pointer :: edgeList !< Output: List of edges in block

      integer :: i, j, k
      type (hashtable) :: h

      call mpas_hash_init(h)

      do i=1,nCells
         do j=1,nEdgesOnCell(i)
            if (.not. mpas_hash_search(h, edgesOnCell(j,i))) call mpas_hash_insert(h, edgesOnCell(j,i)) 
         end do
      end do

      nEdges = mpas_hash_size(h)
      allocate(edgeList(nEdges))

      call mpas_hash_destroy(h)

      call mpas_hash_init(h)

      k = 0
      do i=1,nCells
         do j=1,nEdgesOnCell(i)
            if (.not. mpas_hash_search(h, edgesOnCell(j,i))) then
               k = k + 1
               if (k > nEdges) then
                 call mpas_log_write('block_decomp_all_edges_in_block: ' // &
                    'Trying to add more edges than expected.', MPAS_LOG_CRIT)
                 return
               end if
               edgeList(k) = edgesOnCell(j,i)
               call mpas_hash_insert(h, edgesOnCell(j,i)) 
            end if
         end do
      end do

      call mpas_hash_destroy(h)

      if (k < nEdges) then
         call mpas_log_write('block_decomp_all_edges_in_block: ' // &
            'Listed fewer edges than expected.', MPAS_LOG_CRIT)
      end if

   end subroutine mpas_block_decomp_all_edges_in_block!}}}

!***********************************************************************
!
!  routine mpas_block_decomp_add_halo
!
!> \brief   Add halo to block
!> \author  Doug Jacobsen
!> \date    03/26/13
!> \details 
!>  This routine adds a halo layer to the block.
!
!-----------------------------------------------------------------------
   subroutine mpas_block_decomp_add_halo(dminfo, local_graph_info, local_graph_with_halo)!{{{

      implicit none

      type (dm_info), intent(in) :: dminfo !< Input: Domain information
      type (graph), intent(in) :: local_graph_info !< Input: Local graph structure for a block
      type (graph), intent(out) :: local_graph_with_halo !< Output: Local graph structure for a block, with an extra halo

      integer :: i, j, k
      type (hashtable) :: h


      call mpas_hash_init(h)

      do i=1,local_graph_info % nVertices
         call mpas_hash_insert(h, local_graph_info % vertexID(i))
      end do

      do i=1,local_graph_info % nVertices
         do j=1,local_graph_info % nAdjacent(i)
            if (local_graph_info % adjacencyList(j,i) /= 0) then
               if (.not. mpas_hash_search(h, local_graph_info % adjacencyList(j,i))) then
                  call mpas_hash_insert(h, local_graph_info % adjacencyList(j,i))
               end if
            end if
         end do
      end do 


      local_graph_with_halo % nVertices = local_graph_info % nVertices
      local_graph_with_halo % maxDegree = local_graph_info % maxDegree
      local_graph_with_halo % nVerticesTotal = mpas_hash_size(h)
      local_graph_with_halo % ghostStart = local_graph_with_halo % nVertices + 1
      allocate(local_graph_with_halo % vertexID(local_graph_with_halo % nVerticesTotal))
      allocate(local_graph_with_halo % nAdjacent(local_graph_with_halo % nVerticesTotal))
      allocate(local_graph_with_halo % adjacencyList(local_graph_with_halo % maxDegree, local_graph_with_halo % nVerticesTotal))

      call mpas_hash_destroy(h)

      call mpas_hash_init(h)

      do i=1,local_graph_info % nVertices
         if (mpas_hash_search(h, local_graph_info % vertexID(i))) &
           call mpas_log_write('block_decomp_add_halo: ' // &
             'There appear to be duplicates in vertexID list.', MPAS_LOG_CRIT)
         call mpas_hash_insert(h, local_graph_info % vertexID(i)) 
         local_graph_with_halo % vertexID(i) = local_graph_info % vertexID(i) 
         local_graph_with_halo % nAdjacent(i) = local_graph_info % nAdjacent(i) 
         local_graph_with_halo % adjacencyList(:,i) = local_graph_info % adjacencyList(:,i) 
      end do

      k = local_graph_with_halo % ghostStart
      if (mpas_hash_size(h) /= k-1) &
         call mpas_log_write('block_decomp_add_halo: ' // &
           'Somehow we don''t have the right number of non-ghost cells.', MPAS_LOG_CRIT)
      do i=1,local_graph_info % nVertices
         do j=1,local_graph_info % nAdjacent(i)
            if (local_graph_info % adjacencyList(j,i) /= 0) then
               if (.not. mpas_hash_search(h, local_graph_info % adjacencyList(j,i))) then
                  call mpas_hash_insert(h, local_graph_info % adjacencyList(j,i))
                  local_graph_with_halo % vertexID(k) = local_graph_info % adjacencyList(j,i)
                  k = k + 1
               end if
            end if
         end do
      end do 
      if (local_graph_with_halo % nVerticesTotal /= k-1) &
         call mpas_log_write('block_decomp_add_halo: ' // &
           'Somehow we don''t have the right number of total cells.', MPAS_LOG_CRIT)

      call mpas_hash_destroy(h)

   end subroutine mpas_block_decomp_add_halo!}}}

!***********************************************************************
!
!  routine mpas_get_blocks_per_proc
!
!> \brief   Determine number of blocks per processor
!> \author  Doug Jacobsen
!> \date    03/26/13
!> \details 
!>  This routine returns the number of blocks a specific processor owns.
!
!-----------------------------------------------------------------------
   subroutine mpas_get_blocks_per_proc(dminfo, proc_number, blocks_per_proc)!{{{
     type(dm_info), intent(in) :: dminfo !< Input: Domain Information
     integer, intent(in) :: proc_number !< Input: Processor number
     integer, intent(out) :: blocks_per_proc !< Output: Number of blocks proc_number computes on

     integer :: blocks_per_proc_min, even_blocks, remaining_blocks
     integer :: i, owning_proc, local_block_id

     if(.not. dminfo % explicitDecomp) then
       if(dminfo % total_blocks > dminfo % nProcs) then
         blocks_per_proc_min = dminfo % total_blocks / dminfo % nProcs
         remaining_blocks = dminfo % total_blocks - (blocks_per_proc_min * dminfo % nProcs)
         even_blocks = dminfo % total_blocks - remaining_blocks
  
         blocks_per_proc = blocks_per_proc_min
  
         if(proc_number < remaining_blocks) then
           blocks_per_proc = blocks_per_proc + 1
         end if
       else
         if(dminfo % my_proc_id < dminfo % total_blocks) then
           blocks_per_proc = 1
         else
           blocks_per_proc = 0
         end if
       end if
     else
       blocks_per_proc = 0
       do i = 0, dminfo % total_blocks-1
         call mpas_get_owning_proc(dminfo, i, owning_proc)
         if(owning_proc == proc_number) then
           call mpas_get_local_block_id(dminfo, i, local_block_id)
           blocks_per_proc = max(blocks_per_proc, local_block_id+1)
         end if
       end do
     end if

   end subroutine mpas_get_blocks_per_proc!}}}

!***********************************************************************
!
!  routine mpas_get_local_block_id
!
!> \brief   Determine the local ID of a block
!> \author  Doug Jacobsen
!> \date    03/26/13
!> \details 
!>  This routine returns the local block ID on the owning processor.
!
!-----------------------------------------------------------------------
   subroutine mpas_get_local_block_id(dminfo, global_block_number, local_block_number)!{{{
     type(dm_info), intent(in) :: dminfo !< Input: Domain Information
     integer, intent(in) :: global_block_number !< Input: Global block id from 0 to config_number_of_blocks-1
     integer, intent(out) :: local_block_number !< Output: Local block id on owning processor from 0 to blocks_per_proc

     integer :: blocks_per_proc_min, even_blocks, remaining_blocks

     if(.not.dminfo % explicitDecomp) then
       if(dminfo % total_blocks > dminfo % nProcs) then
         blocks_per_proc_min = dminfo % total_blocks / dminfo % nProcs
         remaining_blocks = dminfo % total_blocks - (blocks_per_proc_min * dminfo % nProcs)
         even_blocks = dminfo % total_blocks - remaining_blocks
  
         if(global_block_number > even_blocks) then
             local_block_number = blocks_per_proc_min
         else
             local_block_number = mod(global_block_number, blocks_per_proc_min)
         end if
       else
         local_block_number = 0
       end if
     else
       local_block_number = dminfo % block_local_id_list(global_block_number+1)
     end if
   end subroutine mpas_get_local_block_id!}}}

!***********************************************************************
!
!  routine mpas_get_owning_proc
!
!> \brief   Determine the owning processor ID for a specific block.
!> \author  Doug Jacobsen
!> \date    03/26/13
!> \details 
!>  This routine returns the ID of the processor that owns a specific block.
!
!-----------------------------------------------------------------------
   subroutine mpas_get_owning_proc(dminfo, global_block_number, owning_proc)!{{{
     type(dm_info), intent(in) :: dminfo !< Input: Domain Information
     integer, intent(in) :: global_block_number !< Input: Global block id from 0 to config_number_of_blocks-1
     integer, intent(out) :: owning_proc !< Output: Processor number that owns block global_block_number

     integer :: blocks_per_proc_min, even_blocks, remaining_blocks

     if(.not.dminfo % explicitDecomp) then
       if(dminfo % total_blocks >= dminfo % nProcs) then
         blocks_per_proc_min = dminfo % total_blocks / dminfo % nProcs
         remaining_blocks = dminfo % total_blocks - (blocks_per_proc_min * dminfo % nProcs)
         even_blocks = dminfo % total_blocks - remaining_blocks

         if((global_block_number+1) > even_blocks) then
             owning_proc = global_block_number - even_blocks
         else
             owning_proc = global_block_number / blocks_per_proc_min
         end if
       else
         owning_proc = global_block_number
       end if
     else
       owning_proc = dminfo % block_proc_list(global_block_number+1)
     end if
   end subroutine mpas_get_owning_proc!}}}

!***********************************************************************
!
!  routine mpas_build_block_proc_list
!
!> \brief   Build list of blocks per processor
!> \author  Doug Jacobsen
!> \date    03/26/13
!> \details 
!>  This routine builds the mapping of blocks to processors. Most useful when using an explicit decomposition.
!
!-----------------------------------------------------------------------
   subroutine mpas_build_block_proc_list(dminfo, procFilePrefix)!{{{

     implicit none

     type(dm_info), intent(inout) :: dminfo !< Input: Domain information
     character (len=*), intent(in) :: procFilePrefix

     integer :: iounit, istatus, i, owning_proc
     character (len=StrKIND) :: filename

     integer, dimension(:), allocatable :: block_counter

     if(.not.dminfo % explicitDecomp) return

     allocate(dminfo % block_proc_list(dminfo % total_blocks))
     allocate(dminfo % block_local_id_list(dminfo % total_blocks))

     if (dminfo % my_proc_id == IO_NODE) then
         allocate(block_counter(dminfo % nProcs))
         block_counter = 0

         if (dminfo % nProcs < 10) then
            write(filename,'(a,i1)') trim(procFilePrefix), dminfo % nProcs
         else if (dminfo % nProcs < 100) then
            write(filename,'(a,i2)') trim(procFilePrefix), dminfo % nProcs
         else if (dminfo % nProcs < 1000) then
            write(filename,'(a,i3)') trim(procFilePrefix), dminfo % nProcs
         else if (dminfo % nProcs < 10000) then
            write(filename,'(a,i4)') trim(procFilePrefix), dminfo % nProcs
         else if (dminfo % nProcs < 100000) then
            write(filename,'(a,i5)') trim(procFilePrefix), dminfo % nProcs
         else if (dminfo % nProcs < 1000000) then
            write(filename,'(a,i6)') trim(procFilePrefix), dminfo % nProcs
         else if (dminfo % nProcs < 10000000) then
            write(filename,'(a,i7)') trim(procFilePrefix), dminfo % nProcs
         end if        

         call mpas_new_unit(iounit)
         open(unit=iounit, file=trim(filename), form='formatted', status='old', iostat=istatus)

         do i=1,dminfo % total_blocks
           read(unit=iounit, fmt=*) owning_proc

           dminfo % block_proc_list(i) = owning_proc
           dminfo % block_local_id_list(i) = block_counter(owning_proc+1)

           block_counter(owning_proc+1) = block_counter(owning_proc+1) + 1
         end do

         close(unit=iounit)
         call mpas_release_unit(iounit)
         deallocate(block_counter)
         call mpas_dmpar_bcast_ints(dminfo, dminfo % total_blocks, dminfo % block_proc_list)
         call mpas_dmpar_bcast_ints(dminfo, dminfo % total_blocks, dminfo % block_local_id_list)
     else
         call mpas_dmpar_bcast_ints(dminfo, dminfo % total_blocks, dminfo % block_proc_list)
         call mpas_dmpar_bcast_ints(dminfo, dminfo % total_blocks, dminfo % block_local_id_list)
     endif

   end subroutine mpas_build_block_proc_list!}}}

!***********************************************************************
!
!  routine mpas_finish_block_proc_list
!
!> \brief   Destroy list of blocks per processor
!> \author  Doug Jacobsen
!> \date    03/26/13
!> \details 
!>  This routine destroys the mapping of blocks to processors.
!
!-----------------------------------------------------------------------
   subroutine mpas_finish_block_proc_list(dminfo)!{{{
     type (dm_info), intent(inout) :: dminfo

     if(.not.dminfo % explicitDecomp) return
     deallocate(dminfo % block_proc_list)
     deallocate(dminfo % block_local_id_list)
   end subroutine mpas_finish_block_proc_list!}}}

end module mpas_block_decomp
