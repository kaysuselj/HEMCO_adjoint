!------------------------------------------------------------------------------
!                   Harmonized Emissions Component (HEMCO)                    !
!------------------------------------------------------------------------------
!BOP
!
! !MODULE: hcox_Iodine_mod.F90
!
! !DESCRIPTION: Module HCOX\_Iodine\_Mod contains routines to calculate
! oceanic iodine emissions (HOI and I2), following carpenter et al. (2014).
! The emission is parameterised herein using online feilds for O3, 10 metre
! wind speed, and ocean surface iodide concentration (parameterised from
! STT following Chance et al (2014)).
!\\
!\\
! This is a HEMCO extension module that uses many of the HEMCO core
! utilities.
!\\
!\\
! !INTERFACE:
!
MODULE HCOX_Iodine_Mod
!
! !USES:
!
  USE HCO_Error_Mod
  USE HCO_Diagn_Mod
  USE HCO_State_Mod,  ONLY : HCO_State
  USE HCOX_State_Mod, ONLY : Ext_State

  IMPLICIT NONE
  PRIVATE
!
! !PUBLIC MEMBER FUNCTIONS:
!
  PUBLIC :: HCOX_Iodine_Init
  PUBLIC :: HCOX_Iodine_Run
  PUBLIC :: HCOX_Iodine_Final
!
! !PRIVATE MEMBER FUNCTIONS:
!
! N/A
!
! !REVISION HISTORY:
!  15 Mar 2013 - T. Sherwen - Initial implementation (v9-3-01)
!  See https://github.com/geoschem/hemco for complete history
!EOP
!------------------------------------------------------------------------------
!
! !PRIVATE TYPES:
!
  TYPE :: MyInst
   ! Tracer IDs
   INTEGER                :: Instance
   INTEGER                :: ExtNr
   INTEGER                :: IDTI2            ! I2 model species ID
   INTEGER                :: IDTHOI           ! HOI model species ID
   LOGICAL                :: CalcI2           ! Calculate I2 oceanic emissions?
   LOGICAL                :: CalcHOI          ! Calculate HOI oceanic emissions?
   TYPE(MyInst), POINTER  :: NextInst => NULL()
  END TYPE MyInst

  ! Pointer to instances
  TYPE(MyInst), POINTER   :: AllInst => NULL()
!
! !DEFINED PARAMETERS:
!
   ! Molecular weight of I2 [kg/mol]
   REAL*8,  PARAMETER   :: MWT_I2 = 2.54d-1
   ! Molecular weight of HOI [kg/mol]
   REAL*8,  PARAMETER   :: MWT_HOI = 1.44d-1

CONTAINS
!EOC
!-------------------------------------------------------------------------------
!                   Harmonized Emissions Component (HEMCO)                    !
!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: HCOX_Iodine_Run
!
! !DESCRIPTION: Subroutine HcoX\_Iodine\_Run is the driver run routine to
! calculate ocean inorganic iodine emissions in HEMCO.
!\\
!\\
! !INTERFACE:
!
  SUBROUTINE HCOX_Iodine_Run( ExtState, HcoState, RC )
!
! !USES:
!
    USE HCO_FluxArr_Mod,      ONLY : HCO_EmisAdd
    USE HCO_GeoTools_Mod,     ONLY : HCO_LANDTYPE
!
! !INPUT PARAMETERS:
!
    TYPE(HCO_State), POINTER       :: HcoState   ! Output obj
    TYPE(Ext_State), POINTER       :: ExtState   ! Module options
!
! !INPUT/OUTPUT PARAMETERS:
!
    INTEGER,         INTENT(INOUT) :: RC         ! Success or failure?
!
! !REMARKS:
!  References:
!  ============================================================================
!  (1) Carpenter et al. 2013, https://doi.org/10.1038/ngeo1687
!  (2) Chance et al. 2014, https://doi.org/10.1039/c4em00139g
!  (3) Macdonal et al. 2014, https://doi.org/10.5194/acp-14-5841-2014
!  (4) Sherwen et al. 2016a, https://doi.org/10.5194/acp-16-1161-2016
!  (5) Sherwen et al. 2016b, https://doi.org/10.5194/acp-16-12239-2016
!
! !REVISION HISTORY:
!  15 Mar 2013 - T. Sherwen - Initial implementation (v9-3-01)
!  See https://github.com/geoschem/hemco for complete history
!EOP
!------------------------------------------------------------------------------
!BOC
!
! !LOCAL VARIABLES:
!
    INTEGER               :: I, J
    REAL*8                :: EMIS_HOI
    REAL*8                :: EMIS_I2, IODIDE, O3_CONC
    REAL*8                :: SST
    REAL*8                :: A_M2
    REAL*8                :: W10M
    REAL(hp),     TARGET  :: FLUXHOI(HcoState%NX,HcoState%NY)
    REAL(hp),     TARGET  :: FLUXI2(HcoState%NX,HcoState%NY)
    TYPE(MyInst), POINTER :: Inst

    ! Error handling
    LOGICAL               :: ERR
    CHARACTER(LEN=255)    :: MSG, LOC

    !=================================================================
    ! HCOX_Iodine_Run begins here!
    !=================================================================
    LOC = 'HCOX_Iodine_Run (HCOX_IODINE_MOD.F90)'

    ! Return if extension disabled
    IF ( ExtState%Inorg_Iodine <= 0 ) RETURN

    ! Enter
    CALL HCO_ENTER ( HcoState%Config%Err, LOC, RC )
    IF ( RC /= HCO_SUCCESS ) THEN
        CALL HCO_ERROR( 'ERROR 0', RC, THISLOC=LOC )
        RETURN
    ENDIF

    ! Exit status
    ERR = .FALSE.

    ! Get instance
    Inst   => NULL()
    CALL InstGet ( ExtState%Inorg_Iodine, Inst, RC )
    IF ( RC /= HCO_SUCCESS ) THEN
       WRITE(MSG,*) 'Cannot find iodine instance Nr. ', ExtState%Inorg_Iodine
       CALL HCO_ERROR(MSG,RC)
       RETURN
    ENDIF

    ! Initialize flux arrays/variables
    FLUXHOI  = 0.0_hp
    FLUXI2   = 0.0_hp

    !------------------------------------------------------------------------
    ! Compute emissions
    !------------------------------------------------------------------------
    !$OMP PARALLEL DO                                                        &
    !$OMP DEFAULT( SHARED                                                   )&
    !$OMP PRIVATE( I,      J,       A_M2,    W10M,     SST                  )&
    !$OMP PRIVATE( IODIDE, O3_CONC, EMIS_I2, EMIS_HOI                       )&
    !$OMP COLLAPSE( 2                                                       )&
    !$OMP SCHEDULE( DYNAMIC, 4                                              )
    DO J = 1, HcoState%NY
    DO I = 1, HcoState%NX

       ! Zero private variables for safety's sake
       A_M2     = 0.0d0
       EMIS_HOI = 0.0d0
       EMIS_I2  = 0.0d0
       IODIDE   = 0.0d0
       O3_CONC  = 0.0d0
       SST      = 0.0d0
       W10M     = 0.0d0

       ! Advance to next grid box if box is not over ocean
       IF ( HCO_LANDTYPE( ExtState%FRLAND%Arr%Val(I,J),   &
                          ExtState%FRLANDIC%Arr%Val(I,J), &
                          ExtState%FROCEAN%Arr%Val(I,J),  &
                          ExtState%FRSEAICE%Arr%Val(I,J), &
                          ExtState%FRLAKE%Arr%Val(I,J) ) /= 0 ) CYCLE

       ! Grid box surface area on simulation grid [m2]
       A_M2 = HcoState%Grid%AREA_M2%Val( I, J )

       ! Wind speed at 10 m altitude [m/s]
       W10M = SQRT( ExtState%U10M%Arr%Val(I,J)**2                            &
                  + ExtState%V10M%Arr%Val(I,J)**2                           )

       ! limit W10M to a minimium of 5 m/s to avoid overestimation of fluxes
       ! from CARPENTER et al. (2013) (per. comm.)
       IF ( W10M .LE. 5.0d0  ) W10M = 5.0d0

!%%% Comment out unused code (bmy, 09 Mar 2022)
!%%%!       ! Sea surface temperature in Celcius
!%%%!       SST = ExtState%TSKIN%Arr%Val(I,J) - 273.15d0

       ! Sea surface temperature in Kelvin
       SST = ExtState%TSKIN%Arr%Val(I,J)

!%%%% Comment out unused code (bmy, 09 Mar 2022)
!%%%#if defined( MODEL_GEOS )
!%%%!       ! Empirical SST scaling factor (jaegle 5/11/11)
!%%%!       SCALE = 0.329d0 + 0.0904d0*SST - &
!%%%!               0.00717d0*SST**2d0 + 0.000207d0*SST**3d0
!%%%#endif
!%%%!
!%%%!       ! SST dependence of iodide - Chance et al. 2014
!%%%!       IODIDE = ( (0.225d0 * ( (SST)**2d0) )  + 19d0 )  / 1d9

       ! SST dependence of iodide - Macdonald et al. 2014
       IODIDE = 1.46d6 * EXP( (-9134d0/SST) )

       ! Get O3 concentration at the surface ( in mol/mol )
       ! ExtState%O3 is in units of kg/kg dry air
       O3_CONC = ExtState%O3%Arr%Val(I,J,1)                                  &
               * HcoState%Phys%AIRMW / 48.0_dp                               &
               * 1.0e9_dp

!%%% Comment out unused code (bmy, 09 Mar 2022)
!%%%#if defined( MODEL_GEOS )
!%%%       ! Reset to using original Gong (2003) emissions (jaegle 6/30/11)
!%%%       !SCALE = 1.0d0
!%%%
!%%%       ! Eventually apply wind scaling factor.
!%%%!       SCALE = SCALE * WindScale
!%%%#endif

       !---------------------------------------------------------------------
       ! If I2 & emitting, use parameterisation from
       ! Carpenter et al (2013) to give emissions in nmol m-2 d-1.
       ! Then convert this to kg/m2/s
       !---------------------------------------------------------------------
       IF ( Inst%CalcI2 ) THEN
           EMIS_I2 = ( O3_CONC * (IODIDE**1.3d0) *                           &
               ( ( 1.74d9 - ( 6.54d8*LOG( W10M ) )   ) )/                    &
                     24d0/60d0/60d0/1d9*MWT_I2 )

          ! If parametsation results in negative ( W10 too high )
          ! flux set to zero
          IF ( EMIS_I2 .LT. 0.0d0 ) EMIS_I2 = 0.0d0

          ! store I2 flux in tendency array in [kg/m2/s]
          FLUXI2(I,J) = EMIS_I2

       ENDIF

       !---------------------------------------------------------------------
       ! If HOI & emitting, use parameterisation from
       ! Carpenter et al (2013) to give emissions in nmol m-2 d-1.
       ! Then convert this to kg/m2/s
       !---------------------------------------------------------------------
       IF ( Inst%CalcHOI ) THEN

          EMIS_HOI =  O3_CONC *                                              &
             ( ( 4.15d5 * ( SQRT(IODIDE)/ W10M ) ) -                         &
             ( 20.6 / W10M ) - ( 2.36d4  * SQRT(IODIDE) ) ) /                &
                      24d0/60d0/60d0/1d9*MWT_HOI

          ! If parametsation results in negative ( W10 too high )
          ! flux set to zero
          IF ( EMIS_HOI .LT. 0.0d0 ) EMIS_HOI = 0.0d0

          ! Store HOI flux in tendency array in [kg/m2/s]
          FLUXHOI(I,J) = EMIS_HOI
       ENDIF

    ENDDO !I
    ENDDO !J
    !$OMP END PARALLEL DO

    ! Check exit status
    IF ( ERR ) THEN
       RC = HCO_FAIL
       RETURN
    ENDIF

    !=================================================================
    ! PASS TO HEMCO STATE AND UPDATE DIAGNOSTICS
    !=================================================================

    ! HOI
    IF ( Inst%CalcHOI ) THEN

       ! Add flux to emission array
       CALL HCO_EmisAdd( HcoState, FLUXHOI, Inst%IDTHOI, &
                         RC,       ExtNr=Inst%ExtNr )
       IF ( RC /= HCO_SUCCESS ) THEN
          CALL HCO_ERROR( 'HCO_EmisAdd error: FLUXHOI', RC )
          RETURN
       ENDIF

    ENDIF

    ! I2
    IF ( Inst%CalcI2 ) THEN

       ! Add flux to emission array
       CALL HCO_EmisAdd( HcoState, FLUXI2, Inst%IDTI2, &
                         RC,       ExtNr=Inst%ExtNr )
       IF ( RC /= HCO_SUCCESS ) THEN
          CALL HCO_ERROR( 'HCO_EmisAdd error: FLUXI2', RC )
          RETURN
       ENDIF

    ENDIF

    ! Cleanup
    Inst => NULL()

    ! Leave w/ success
    CALL HCO_LEAVE ( HcoState%Config%Err, RC )

  END SUBROUTINE HCOX_Iodine_Run

!EOC
!------------------------------------------------------------------------------
!                   Harmonized Emissions Component (HEMCO)                    !
!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: HCOX_Iodine_Init
!
! !DESCRIPTION: Subroutine HcoX\_Iodine\_Init initializes all
!  extension variables.
!\\
!\\
! !INTERFACE:
!
  SUBROUTINE HCOX_Iodine_Init( HcoState, ExtName, ExtState, RC )
!
! !USES:
!
    USE HCO_State_Mod,          ONLY : HCO_GetHcoID
    USE HCO_STATE_MOD,          ONLY : HCO_GetExtHcoID
    USE HCO_ExtList_Mod,        ONLY : GetExtNr
    USE HCO_ExtList_Mod,        ONLY : GetExtOpt
!
! !INPUT PARAMETERS:
!
    TYPE(HCO_State),  POINTER        :: HcoState    ! HEMCO state object
    CHARACTER(LEN=*), INTENT(IN   )  :: ExtName     ! Extension name
    TYPE(Ext_State),  POINTER        :: ExtState    ! Options object
!
! !INPUT/OUTPUT PARAMETERS:
!
    INTEGER,          INTENT(INOUT)  :: RC          ! Return status
!
! !REVISION HISTORY:
!  15 Mar 2013 - T. Sherwen - Initial implementation (v9-3-01)
!  See https://github.com/geoschem/hemco for complete history
!EOP
!------------------------------------------------------------------------------
!BOC
!
! !LOCAL VARIABLES:
!
    INTEGER                        :: ExtNr, N, R, AS
    CHARACTER(LEN=255)             :: MSG, LOC
    INTEGER                        :: nSpc, minLen
    LOGICAL                        :: FOUND
    INTEGER, ALLOCATABLE           :: HcoIDs(:)
    CHARACTER(LEN=31), ALLOCATABLE :: SpcNames(:)
    TYPE(MyInst), POINTER          :: Inst

    !=================================================================
    ! HCOX_Iodine_Init begins here!
    !=================================================================
    LOC = 'HCOX_Iodine_Init (HCOX_IODINE_MOD.F90)'

    ! Extension Nr.
    ExtNr = GetExtNr( HcoState%Config%ExtList, TRIM(ExtName) )
    IF ( ExtNr <= 0 ) RETURN

    ! Enter
    CALL HCO_ENTER ( HcoState%Config%Err, LOC, RC )
    IF ( RC /= HCO_SUCCESS ) THEN
        CALL HCO_ERROR( 'ERROR 1', RC, THISLOC=LOC )
        RETURN
    ENDIF

    ! Init
    Inst => NULL()

    ! Create Instance
    CALL InstCreate ( ExtNr, ExtState%Inorg_Iodine, Inst, RC )
    IF ( RC /= HCO_SUCCESS ) THEN
       CALL HCO_ERROR ( 'Cannot create InorgIodine instance', RC )
       RETURN
    ENDIF

    ! ----------------------------------------------------------------------
    ! Get species IDs and settings
    ! ----------------------------------------------------------------------

    ! Read settings specified in configuration file
    ! Note: the specified strings have to match those in
    !       the config. file!
    CALL GetExtOpt ( HcoState%Config, Inst%ExtNr, 'Emit I2',  &
                     OptValBool=Inst%CalcI2, RC=RC )
    IF ( RC /= HCO_SUCCESS ) THEN
        CALL HCO_ERROR( 'ERROR 2', RC, THISLOC=LOC )
        RETURN
    ENDIF

    CALL GetExtOpt ( HcoState%Config, Inst%ExtNr, 'Emit HOI', &
                     OptValBool=Inst%CalcHOI, RC=RC )
    IF ( RC /= HCO_SUCCESS ) THEN
        CALL HCO_ERROR( 'ERROR 3', RC, THISLOC=LOC )
        RETURN
    ENDIF

    ! Set minimum length and update if CalcI2/CalcHOI==True
    minLen = 0
    IF ( Inst%CalcI2 ) THEN
       minLen = minLen +1
    ENDIF
    IF ( Inst%CalcHOI ) THEN
       minLen = minLen +1
    ENDIF
    ! Get HEMCO species IDs
    CALL HCO_GetExtHcoID( HcoState, Inst%ExtNr, HcoIDs, SpcNames, nSpc, RC )
    IF ( RC /= HCO_SUCCESS ) THEN
        CALL HCO_ERROR( 'ERROR 4', RC, THISLOC=LOC )
        RETURN
    ENDIF
    IF ( nSpc < minLen ) THEN
       MSG = 'Not enough iodine emission species set'
       CALL HCO_ERROR ( MSG, RC )
       RETURN
    ENDIF

    Inst%IDTHOI = HcoIDs(1)
    Inst%IDTI2 = HcoIDs(2)

    ! Final I2/HOI flag
    Inst%CalcI2 = ( Inst%CalcI2 .AND. Inst%IDTI2 > 0 )
    Inst%CalcHOI = ( Inst%CalcHOI .AND. Inst%IDTHOI > 0 )

    ! Verbose mode
    IF ( HcoState%amIRoot ) THEN

       ! Write the name of the extension regardless of the verbose setting
       msg = 'Using HEMCO extension: Inorg_Iodine (HOI and I2 emissions)'
       CALL HCO_Msg( msg, sep1='-', LUN=HcoState%Config%hcoLogLUN ) ! with separator

       ! Write all other messages as debug printout only
       IF ( Inst%CalcHOI ) THEN
          WRITE(MSG,*) 'HOI: ', TRIM(SpcNames(1)), Inst%IDTHOI
          CALL HCO_MSG( msg, LUN=HcoState%Config%hcoLogLUN )
       ENDIF

       IF ( Inst%CalcI2 ) THEN
          WRITE(MSG,*) 'I2: ', TRIM(SpcNames(2)), Inst%IDTI2
          CALL HCO_MSG( msg, LUN=HcoState%Config%hcoLogLUN )
       ENDIF
    ENDIF

    !=======================================================================
    ! Activate this module and the fields of ExtState that it uses
    !=======================================================================

    ! Activate met fields used by this module
    ExtState%FRLAND%DoUse   = .TRUE.
    ExtState%FRLANDIC%DoUse = .TRUE.
    ExtState%FROCEAN%DoUse  = .TRUE.
    ExtState%FRSEAICE%DoUse = .TRUE.
    ExtState%FRLAKE%DoUse   = .TRUE.
    ExtState%TSKIN%DoUse    = .TRUE.
    ExtState%U10M%DoUse     = .TRUE.
    ExtState%V10M%DoUse     = .TRUE.
    ExtState%O3%DoUse       = .TRUE.
    ExtState%AIR%DoUse      = .TRUE.

    ! Enable module
    !ExtState%Inorg_Iodine = .TRUE.

    ! Return w/ success
    Inst => NULL()
    IF ( ALLOCATED(HcoIDs  ) ) DEALLOCATE(HcoIDs  )
    IF ( ALLOCATED(SpcNames) ) DEALLOCATE(SpcNames)
    CALL HCO_LEAVE ( HcoState%Config%Err, RC )

  END SUBROUTINE HCOX_Iodine_Init

!EOC
!------------------------------------------------------------------------------
!                   Harmonized Emissions Component (HEMCO)                    !
!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: HCOX_Iodine_Final
!
! !DESCRIPTION: Subroutine HcoX\_Iodine\_Final deallocates
!  all module arrays.
!\\
!\\
! !INTERFACE:
!
  SUBROUTINE HCOX_Iodine_Final ( ExtState )
!
! !INPUT PARAMETERS:
!
    TYPE(Ext_State),  POINTER       :: ExtState   ! Module options
!
! !REVISION HISTORY:
!  15 Mar 2013 - T. Sherwen - Initial implementation (v9-3-01)
!  See https://github.com/geoschem/hemco for complete history
!EOP
!------------------------------------------------------------------------------
!BOC
!
    !=================================================================
    ! HCOX_Iodine_Final begins here!
    !=================================================================
    CALL InstRemove ( ExtState%Inorg_Iodine )

    ! Cleanup module arrays
!    IF ( ALLOCATED ( HcoIDs     ) ) DEALLOCATE( HcoIDs      )
!    IF ( ALLOCATED ( SpcNames   ) ) DEALLOCATE( SpcNames    )

  END SUBROUTINE HCOX_Iodine_Final
!EOC
!------------------------------------------------------------------------------
!                   Harmonized Emissions Component (HEMCO)                    !
!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: InstGet
!
! !DESCRIPTION: Subroutine InstGet returns a poiner to the desired instance.
!\\
!\\
! !INTERFACE:
!
  SUBROUTINE InstGet ( Instance, Inst, RC, PrevInst )
!
! !INPUT PARAMETERS:
!
    INTEGER                             :: Instance
    TYPE(MyInst),     POINTER           :: Inst
    INTEGER                             :: RC
    TYPE(MyInst),     POINTER, OPTIONAL :: PrevInst
!
! !REVISION HISTORY:
!  18 Feb 2016 - C. Keller   - Initial version
!  See https://github.com/geoschem/hemco for complete history
!EOP
!------------------------------------------------------------------------------
!BOC
    TYPE(MyInst),     POINTER    :: PrvInst

    !=================================================================
    ! InstGet begins here!
    !=================================================================

    ! Get instance. Also archive previous instance.
    PrvInst => NULL()
    Inst    => AllInst
    DO WHILE ( ASSOCIATED(Inst) )
       IF ( Inst%Instance == Instance ) EXIT
       PrvInst => Inst
       Inst    => Inst%NextInst
    END DO
    IF ( .NOT. ASSOCIATED( Inst ) ) THEN
       RC = HCO_FAIL
       RETURN
    ENDIF

    ! Pass output arguments
    IF ( PRESENT(PrevInst) ) PrevInst => PrvInst

    ! Cleanup & Return
    PrvInst => NULL()
    RC = HCO_SUCCESS

  END SUBROUTINE InstGet
!EOC
!------------------------------------------------------------------------------
!                   Harmonized Emissions Component (HEMCO)                    !
!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: InstCreate
!
! !DESCRIPTION: Subroutine InstCreate creates a new instance.
!\\
!\\
! !INTERFACE:
!
  SUBROUTINE InstCreate ( ExtNr, Instance, Inst, RC )
!
! !INPUT PARAMETERS:
!
    INTEGER,       INTENT(IN)       :: ExtNr
!
! !OUTPUT PARAMETERS:
!
    INTEGER,       INTENT(  OUT)    :: Instance
    TYPE(MyInst),  POINTER          :: Inst
!
! !INPUT/OUTPUT PARAMETERS:
!
    INTEGER,       INTENT(INOUT)    :: RC
!
! !REVISION HISTORY:
!  18 Feb 2016 - C. Keller   - Initial version
!  See https://github.com/geoschem/hemco for complete history
!EOP
!------------------------------------------------------------------------------
!BOC
    TYPE(MyInst), POINTER          :: TmpInst
    INTEGER                        :: nnInst

    !=================================================================
    ! InstCreate begins here!
    !=================================================================

    ! ----------------------------------------------------------------
    ! Generic instance initialization
    ! ----------------------------------------------------------------

    ! Initialize
    Inst => NULL()

    ! Get number of already existing instances
    TmpInst => AllInst
    nnInst = 0
    DO WHILE ( ASSOCIATED(TmpInst) )
       nnInst  =  nnInst + 1
       TmpInst => TmpInst%NextInst
    END DO

    ! Create new instance
    ALLOCATE(Inst)
    Inst%Instance = nnInst + 1
    Inst%ExtNr    = ExtNr

    ! Attach to instance list
    Inst%NextInst => AllInst
    AllInst       => Inst

    ! Update output instance
    Instance = Inst%Instance

    ! ----------------------------------------------------------------
    ! Type specific initialization statements follow below
    ! ----------------------------------------------------------------

    ! Return w/ success
    RC = HCO_SUCCESS

  END SUBROUTINE InstCreate
!EOC
!------------------------------------------------------------------------------
!                   Harmonized Emissions Component (HEMCO)                    !
!------------------------------------------------------------------------------
!BOP
!
! !IROUTINE: InstRemove
!
! !DESCRIPTION: Subroutine InstRemove creates a new instance.
!\\
!\\
! !INTERFACE:
!
  SUBROUTINE InstRemove ( Instance )
!
! !INPUT PARAMETERS:
!
    INTEGER                         :: Instance
!
! !REVISION HISTORY:
!  18 Feb 2016 - C. Keller   - Initial version
!  See https://github.com/geoschem/hemco for complete history
!EOP
!------------------------------------------------------------------------------
!BOC
    INTEGER                     :: RC
    TYPE(MyInst), POINTER       :: PrevInst
    TYPE(MyInst), POINTER       :: Inst

    !=================================================================
    ! InstRemove begins here!
    !=================================================================

    ! Init
    PrevInst => NULL()
    Inst     => NULL()

    ! Get instance. Also archive previous instance.
    CALL InstGet ( Instance, Inst, RC, PrevInst=PrevInst )

    ! Instance-specific deallocation
    IF ( ASSOCIATED(Inst) ) THEN

       ! Pop off instance from list
       IF ( ASSOCIATED(PrevInst) ) THEN
          PrevInst%NextInst => Inst%NextInst
       ELSE
          AllInst => Inst%NextInst
       ENDIF
       DEALLOCATE(Inst)
    ENDIF

    ! Free pointers before exiting
    PrevInst => NULL()
    Inst     => NULL()

   END SUBROUTINE InstRemove
!EOC
END MODULE HCOX_Iodine_Mod
