module trigger

#ifdef MPI
  use message_passing
#endif

  use constants
  use global
  use string,         only: to_str
  use output,         only: warning, write_message
  use mesh,           only: bin_to_mesh_indices
  use mesh_header,    only: RegularMesh
  use trigger_header, only: TriggerObject
  use tally,          only: TallyObject
  use tally_filter,   only: MeshFilter

  implicit none

contains

!===============================================================================
! CHECK_TRIGGERS checks any user-specified precision triggers' for convergence
! and predicts the number of remainining batches to convergence.
!===============================================================================

  subroutine check_triggers()

    implicit none

    ! Variables to reflect distance to trigger convergence criteria
    real(8)            :: max_ratio       ! max uncertainty/thresh ratio
    integer            :: tally_id        ! id for tally with max ratio
    character(len=52)  :: name            ! "eigenvalue" or tally score

    integer    :: n_pred_batches  ! predicted # batches to satisfy all triggers

    ! Checks if current_batch is one for which the triggers must be checked
    if (current_batch < n_batches .or. (.not. trigger_on)) return
    if (mod((current_batch - n_batches), n_batch_interval) /= 0 .and. &
         current_batch /= n_max_batches) return

    ! Check the trigger and output the result
    call check_tally_triggers(max_ratio, tally_id, name)

    ! When trigger threshold is reached, write information
    if (satisfy_triggers) then
      call write_message("Triggers satisfied for batch " // &
           trim(to_str(current_batch)))

    ! When trigger is not reached write convergence info for user
    elseif (name == "eigenvalue") then
      call write_message("Triggers unsatisfied, max unc./thresh. is " // &
           trim(to_str(max_ratio)) //  " for " // trim(name))
    else
      call write_message("Triggers unsatisfied, max unc./thresh. is " // &
           trim(to_str(max_ratio)) // " for " // trim(name) // &
           " in tally " // trim(to_str(tally_id)))
    end if

    ! If batch_interval is not set, estimate batches till triggers are satisfied
    if (pred_batches .and. .not. satisfy_triggers) then

      ! Estimate the number of remaining batches to convergence
      ! The prediction uses the fact that tally variances are proportional
      ! to 1/N where N is the number of the batches/particles
      n_batch_interval = int((current_batch-n_inactive) * &
           (max_ratio ** 2)) + n_inactive-n_batches + 1
      n_pred_batches = n_batch_interval + n_batches

      ! Write the predicted number of batches for the user
      if (n_pred_batches > n_max_batches) then
        call warning("The estimated number of batches is " // &
             trim(to_str(n_pred_batches)) // &
             " --  greater than max batches. ")
      else
        call write_message("The estimated number of batches is " // &
             trim(to_str(n_pred_batches)))
      end if
    end if
  end subroutine check_triggers


!===============================================================================
! CHECK_TALLY_TRIGGERS checks whether uncertainties are below the threshold,
! and finds the maximum  uncertainty/threshold ratio for all triggers
!===============================================================================

  subroutine check_tally_triggers(max_ratio, tally_id, name)

    ! Variables to reflect distance to trigger convergence criteria
    real(8), intent(inout) :: max_ratio       ! max uncertainty/thresh ratio
    integer, intent(inout) :: tally_id        ! id for tally with max ratio
    character(len=52), intent(inout) :: name  ! "eigenvalue" or tally score

    integer :: i              ! index in tallies array
    integer :: n              ! loop index for nuclides
    integer :: s              ! loop index for triggers
    integer :: filter_index   ! index in results array for filters
    integer :: score_index    ! scoring bin index
    integer :: n_order        ! loop index for moment orders
    integer :: nm_order       ! loop index for Ynm moment orders
    real(8) :: uncertainty    ! trigger uncertainty
    real(8) :: std_dev = ZERO ! trigger standard deviation
    real(8) :: rel_err = ZERO ! trigger relative error
    real(8) :: ratio          ! ratio of the uncertainty/trigger threshold
    type(TallyObject), pointer     :: t               ! tally pointer
    type(TriggerObject), pointer   :: trigger         ! tally trigger

    ! Initialize tally trigger maximum uncertainty ratio to zero
    max_ratio = 0

    if (master) then

      ! By default, assume all triggers are satisfied
      satisfy_triggers = .true.

      ! Check eigenvalue trigger
      if (run_mode == MODE_EIGENVALUE) then
        if (keff_trigger % trigger_type /= 0) then
          select case (keff_trigger % trigger_type)
          case(VARIANCE)
            uncertainty = k_combined(2) ** 2
          case(STANDARD_DEVIATION)
            uncertainty = k_combined(2)
          case default
            uncertainty = k_combined(2) / k_combined(1)
          end select

          ! If uncertainty is above threshold, store uncertainty ratio
          if (uncertainty > keff_trigger % threshold) then
            satisfy_triggers = .false.
            if (keff_trigger % trigger_type == VARIANCE) then
              ratio = sqrt(uncertainty / keff_trigger % threshold)
            else
              ratio = uncertainty / keff_trigger % threshold
            end if
            if (max_ratio < ratio) then
              max_ratio = ratio
              name = "eigenvalue"
            end if
          end if
        end if
      end if

      ! Compute uncertainties for all tallies, scores with triggers
      TALLY_LOOP: do i = 1, n_tallies
        t => tallies(i)

        ! Cycle through if only one batch has been simumlate
        if (t % n_realizations == 1) then
          cycle TALLY_LOOP
        end if

        TRIGGER_LOOP: do s = 1, t % n_triggers
          trigger => t % triggers(s)

          ! Initialize trigger uncertainties to zero
          trigger % std_dev = ZERO
          trigger % rel_err = ZERO
          trigger % variance = ZERO

          ! Surface current tally triggers require special treatment
          if (t % type == TALLY_SURFACE_CURRENT) then
            call compute_tally_current(t, trigger)

          else

            ! Initialize bins, filter level
            matching_bins(1:size(t % filters)) = 0

            FILTER_LOOP: do filter_index = 1, t % total_filter_bins

              ! Initialize score index
              score_index = trigger % score_index

              ! Initialize score bin index
              NUCLIDE_LOOP: do n = 1, t % n_nuclide_bins

                select case(t % score_bins(trigger % score_index))

                case (SCORE_SCATTER_PN, SCORE_NU_SCATTER_PN)

                  score_index = score_index - 1

                  do n_order = 0, t % moment_order(trigger % score_index)
                    score_index = score_index + 1

                    call get_trigger_uncertainty(std_dev, rel_err, &
                         score_index, filter_index, t)

                    if (trigger % variance < variance) then
                      trigger % variance = std_dev ** 2
                    end if
                    if (trigger % std_dev < std_dev) then
                      trigger % std_dev = std_dev
                    end if
                    if (trigger % rel_err < rel_err) then
                      trigger % rel_err = rel_err
                    end if

                  end do

                case (SCORE_SCATTER_YN, SCORE_NU_SCATTER_YN, SCORE_FLUX_YN, &
                     SCORE_TOTAL_YN)

                  score_index = score_index - 1

                  do n_order = 0, t % moment_order(trigger % score_index)
                    do nm_order = -n_order, n_order
                      score_index = score_index + 1

                      call get_trigger_uncertainty(std_dev, rel_err, &
                             score_index, filter_index, t)

                      if (trigger % variance < variance) then
                        trigger % variance = std_dev ** 2
                      end if
                      if (trigger % std_dev < std_dev) then
                        trigger % std_dev = std_dev
                      end if
                      if (trigger % rel_err < rel_err) then
                        trigger % rel_err = rel_err
                      end if

                    end do
                  end do

                case default
                  call get_trigger_uncertainty(std_dev, rel_err, &
                       score_index, filter_index, t)

                  if (trigger % variance < variance) then
                    trigger % variance = std_dev ** 2
                  end if
                  if (trigger % std_dev < std_dev) then
                    trigger % std_dev = std_dev
                  end if
                  if (trigger % rel_err < rel_err) then
                    trigger % rel_err = rel_err
                  end if

                end select

                select case (t % triggers(s) % type)
                case(VARIANCE)
                  uncertainty = trigger % variance
                case(STANDARD_DEVIATION)
                  uncertainty = trigger % std_dev
                case default
                  uncertainty = trigger % rel_err
                end select

                if (uncertainty > t % triggers(s) % threshold) then
                  satisfy_triggers = .false.

                  if (t % triggers(s) % type == VARIANCE) then
                    ratio = sqrt(uncertainty / t % triggers(s) % threshold)
                  else
                    ratio = uncertainty / t % triggers(s) % threshold
                  end if

                  if (max_ratio < ratio) then
                    max_ratio = ratio
                    name  = t % triggers(s) % score_name
                    tally_id = t % id
                  end if
                end if
              end do NUCLIDE_LOOP
              if (size(t % filters) == 0) exit FILTER_LOOP
            end do FILTER_LOOP
          end if
        end do TRIGGER_LOOP
      end do TALLY_LOOP
    end if
  end subroutine check_tally_triggers


!===============================================================================
! COMPUTE_TALLY_CURRENT computes the current for a surface current tally with
! precision trigger(s).
!===============================================================================

  subroutine compute_tally_current(t, trigger)

    integer :: i                    ! mesh index
    integer :: ijk(3)               ! indices of mesh cells
    integer :: n_dim                ! number of mesh dimensions
    integer :: n_cells              ! number of mesh cells
    integer :: l                    ! index for energy
    integer :: i_filter_mesh        ! index for mesh filter
    integer :: i_filter_ein         ! index for incoming energy filter
    integer :: i_filter_surf        ! index for surface filter
    integer :: n                    ! number of incoming energy bins
    integer :: filter_index         ! index in results array for filters
    logical :: print_ebin           ! should incoming energy bin be displayed?
    real(8) :: rel_err  = ZERO      ! temporary relative error of result
    real(8) :: std_dev  = ZERO      ! temporary standard deviration of result
    type(TallyObject), pointer    :: t        ! surface current tally
    type(TriggerObject)           :: trigger  ! surface current tally trigger
    type(RegularMesh), pointer :: m        ! surface current mesh

    ! Get pointer to mesh
    i_filter_mesh = t % find_filter(FILTER_MESH)
    i_filter_surf = t % find_filter(FILTER_SURFACE)
    select type(filt => t % filters(i_filter_mesh) % obj)
    type is (MeshFilter)
      m => meshes(filt % mesh)
    end select

    ! initialize bins array
    matching_bins(1:size(t % filters)) = 1

    ! determine how many energyin bins there are
    i_filter_ein = t % find_filter(FILTER_ENERGYIN)
    if (i_filter_ein > 0) then
      print_ebin = .true.
      n = t % filters(i_filter_ein) % obj % n_bins
    else
      print_ebin = .false.
      n = 1
    end if

    ! Get the dimensions and number of cells in the mesh
    n_dim = m % n_dimension
    n_cells = product(m % dimension)

    ! Loop over all the mesh cells
    do i = 1, n_cells

      ! Get the indices for this cell
      call bin_to_mesh_indices(m, i, ijk)
      matching_bins(i_filter_mesh) = i

      do l = 1, n

        if (print_ebin) then
          matching_bins(i_filter_ein) = l
        end if

        ! Left Surface
        matching_bins(i_filter_surf) = OUT_LEFT
        filter_index = &
             sum((matching_bins(1:size(t % filters)) - 1) * t % stride) + 1
        call get_trigger_uncertainty(std_dev, rel_err, 1, filter_index, t)
        if (trigger % std_dev < std_dev) then
          trigger % std_dev = std_dev
        end if
        if (trigger % rel_err < rel_err) then
          trigger % rel_err = rel_err
        end if
        trigger % variance = std_dev**2

        ! Right Surface
        matching_bins(i_filter_surf) = OUT_RIGHT
        filter_index = &
             sum((matching_bins(1:size(t % filters)) - 1) * t % stride) + 1
        call get_trigger_uncertainty(std_dev, rel_err, 1, filter_index, t)
        if (trigger % std_dev < std_dev) then
          trigger % std_dev = std_dev
        end if
        if (trigger % rel_err < rel_err) then
          trigger % rel_err = rel_err
        end if
        trigger % variance = trigger % std_dev**2

        ! Back Surface
        matching_bins(i_filter_surf) = OUT_BACK
        filter_index = &
             sum((matching_bins(1:size(t % filters)) - 1) * t % stride) + 1
        call get_trigger_uncertainty(std_dev, rel_err, 1, filter_index, t)
        if (trigger % std_dev < std_dev) then
          trigger % std_dev = std_dev
        end if
        if (trigger % rel_err < rel_err) then
          trigger % rel_err = rel_err
        end if
        trigger % variance = trigger % std_dev**2

        ! Front Surface
        matching_bins(i_filter_surf) = OUT_FRONT
        filter_index = &
             sum((matching_bins(1:size(t % filters)) - 1) * t % stride) + 1
        call get_trigger_uncertainty(std_dev, rel_err, 1, filter_index, t)
        if (trigger % std_dev < std_dev) then
          trigger % std_dev = std_dev
        end if
        if (trigger % rel_err < rel_err) then
          trigger % rel_err = rel_err
        end if
        trigger % variance = trigger % std_dev**2

        ! Bottom Surface
        matching_bins(i_filter_surf) = OUT_BOTTOM
        filter_index = &
             sum((matching_bins(1:size(t % filters)) - 1) * t % stride) + 1
        call get_trigger_uncertainty(std_dev, rel_err, 1, filter_index, t)
        if (trigger % std_dev < std_dev) then
          trigger % std_dev = std_dev
        end if
        if (trigger % rel_err < rel_err) then
          trigger % rel_err = rel_err
        end if
        trigger % variance = trigger % std_dev**2

        ! Top Surface
        matching_bins(i_filter_surf) = OUT_TOP
        filter_index = &
             sum((matching_bins(1:size(t % filters)) - 1) * t % stride) + 1
        call get_trigger_uncertainty(std_dev, rel_err, 1, filter_index, t)
        if (trigger % std_dev < std_dev) then
          trigger % std_dev = std_dev
        end if
        if (trigger % rel_err < rel_err) then
          trigger % rel_err = rel_err
        end if
        trigger % variance = trigger % std_dev**2

      end do
    end do

  end subroutine compute_tally_current

!===============================================================================
! GET_TRIGGER_UNCERTAINTY computes the standard deviation and relative error
! for a single tally bin for CHECK_TALLY_TRIGGERS.
!===============================================================================

  subroutine get_trigger_uncertainty(std_dev, rel_err, score_index, &
       filter_index, t)

    real(8), intent(inout)     :: std_dev         ! tally standard deviation
    real(8), intent(inout)     :: rel_err         ! tally relative error
    integer, intent(in)        :: score_index     ! tally results score index
    integer, intent(in)        :: filter_index    ! tally results filter index
    type(TallyObject), intent(in) :: t            ! tally

    integer :: n               ! number of realizations
    real(8) :: mean            ! tally mean
    real(8) :: tally_sum, tally_sum_sq     ! results for a single tally bin

    n = t % n_realizations
    tally_sum = t % results(RESULT_SUM, score_index, filter_index)
    tally_sum_sq = t % results(RESULT_SUM_SQ, score_index, filter_index)

    ! Compute the tally mean and standard deviation
    mean    = tally_sum / n
    std_dev = sqrt((tally_sum_sq / n - mean * mean) / (n - 1))

    ! Compute the relative error if the mean is non-zero
    if (mean == ZERO) then
      rel_err = ZERO
    else
      rel_err = std_dev / mean
    end if

  end subroutine get_trigger_uncertainty

end module trigger
