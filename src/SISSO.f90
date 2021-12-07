! Licensed under the Apache License, Version 2.0 (the "License");
! you may not use this file except in compliance with the License.
! You may obtain a copy of the License at
!
!     http://www.apache.org/licenses/LICENSE-2.0
!
! Unless required by applicable law or agreed to in writing, software
! distributed under the License is distributed on an "AS IS" BASIS,
! WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
! See the License for the specific language governing permissions and
! limitations under the License.


program SISSO

use var_global
use libsisso
use FC
use DI
!-------------------

integer i,j,k,l,icontinue
character tcontinue*2,nsample_line*500,isconvex_line*500,line*10000000,dimclass*500
logical fexist

! mpi initialization
call mpi_init(mpierr)
call mpi_comm_size(mpi_comm_world,mpisize,mpierr)
call mpi_comm_rank(mpi_comm_world,mpirank,mpierr)
!---

call random_seed()
call initialization  ! parameters initialization
call read_para_a  ! from SISSO.in
funit=100

if(mpirank==0) then
 stime_FCDI=mpi_wtime()
 if(restart) then
    inquire(file='SISSO.out',exist=fexist)
    if(fexist) call system('mv SISSO.out SISSO.out_old')
 end if
 open(9,file='SISSO.out',status='replace')
 write(9,'(a)') 'Version SISSO.3.0.2, June, 2020.'
 write(9,'(a/)')'================================================================================'
end if

! array allocation
allocate(nsample(ntask))  ! # samples for each property
allocate(ngroup(ntask,1000))  ! (for classification) # of samples in each group of a property
allocate(isconvex(ntask,1000)) ! is the dataset of each group represented by convex domain?
allocate(pfdim(ndimtype,nsf+nvf))
call read_para_b
allocate(prop_y(sum(nsample)))
allocate(psfeat(sum(nsample),nsf))  ! scalar features                                                    
allocate(pfname(nsf+nvf)) ! feature names
allocate(pvfeat(sum(nsample),vfsize,nvf))  ! vector features             
allocate(res(sum(nsample)))

call read_data  ! from train.dat (and train_vf.dat)
if(mpirank==0) call output_para ! output parameters to SISSO.out


! calc: DI or FC or FCDI
!IF(trim(adjustl(calc))=='DI') THEN
!    if(mpirank==0) then
!        write(*,'(/a)') 'DI starts ...'
!        write(*,'(a)') '--------------------------------------------------------------------------------'
!        write(9,'(/a)') 'DI starts ...'
!        write(9,'(a)') '--------------------------------------------------------------------------------'
!    end if
!    call descriptor_identification
!    if(mpirank==0) then
!        write(*,'(a)') 'DI done!'
!        write(*,'(a)') '--------------------------------------------------------------------------------'
!        write(9,'(a)') 'DI Done!'
!        write(9,'(a)') '--------------------------------------------------------------------------------'
!    end if
!    goto 3001
!ELSE IF(trim(adjustl(calc))=='FC') THEN
!    if(trim(adjustl(calc))=='FC') then
!       if(mpirank==0) then
!           write(*,'(/a)') 'FC starts ...'
!           write(*,'(a)') '--------------------------------------------------------------------------------'
!           write(9,'(/a)') 'FC starts ...'
!           write(9,'(a)') '--------------------------------------------------------------------------------'
!       end if
!       call feature_construction
!       if(mpirank==0) then
!           write(*,'(a)') 'FC done!'
!           write(*,'(a)') '--------------------------------------------------------------------------------'
!           write(9,'(a)') 'FC done!'
!           write(9,'(a)') '--------------------------------------------------------------------------------'
!       end if
!       goto 3001
!    end if
!ELSE IF(trim(adjustl(calc))=='FCDI') THEN
!    continue
!END IF

!---------------------
! FCDI starts ...
!---------------------
if(mpirank==0) then
    write(9,'(/a)') 'Feature Construction and Descriptor Identification (FCDI) starts ...'
    write(*,'(/a)') 'Feature Construction and Descriptor Identification (FCDI) starts ...'
end if

if(restart) then
  open(funit,file='CONTINUE',status='old')
     read(funit,*) icontinue
     read(funit,'(a)') tcontinue
     if (tcontinue=='FC') then
        read(funit,*) nsis(:icontinue-1)
     else if (tcontinue=='DI') then
        read(funit,*) nsis(:icontinue)
     end if
  close(funit)
else
  icontinue=1
  tcontinue='FC'
  if(mpirank==0) then
     call system('rm -rf residual')
     call system('rm -rf feature_space')
     call system('rm -rf desc_dat')
     call system('rm -rf models')
     call system('mkdir desc_dat feature_space residual models')
  end if
end if

! iteration starts ...
do iFCDI=icontinue,desc_dim
   if(mpirank==0) then
      write(*,'(/a,i3)') 'iteration: ',iFCDI
      write(*,'(a)') '--------------------------------------------------------------------------------'
      write(9,'(/a,i3)') 'iteration: ',iFCDI
      write(9,'(a)') '--------------------------------------------------------------------------------'
   end if

   if(iFCDI>icontinue .or. (iFCDI==icontinue .and. tcontinue=='FC') ) then
     ! run FC
     if(mpirank==0) then
         write(*,'(a)') 'FC starts ...'
         write(9,'(a)') 'FC starts ...'
     end if

     if(mpirank==0) call writeCONTINUE('FC')
     if(mpirank==0) call prepare4FC
     call mpi_bcast(res,sum(nsample),mpi_double_precision,0,mpi_comm_world,mpierr)
     call mpi_barrier(mpi_comm_world,mpierr)
     call feature_construction
     if(mpirank==0) then
         write(*,'(a)') 'FC done!'
         write(9,'(a)') 'FC done!'
     end if
   end if

   ! run DI
   if(mpirank==0) then
        write(*,'(/a)') 'DI starts ...'
        write(9,'(/a)') 'DI starts ...'
   end if

   fs_size_DI=sum(nsis(:iFCDI))  ! feature space for DI
   if(mpirank==0) write(9,'(a,i10)') 'total number of SIS-selected features from all iterations: ',sum(nsis(:iFCDI))
   if(trim(adjustl(method))=='L0') then  ! feature space for L0
      fs_size_L0=fs_size_DI
   else if(trim(adjustl(method))=='L1L0') then
      fs_size_L0=L1L0_size4L0
   end if

   if(mpirank==0) call writeCONTINUE('DI')
   if(mpirank==0) call prepare4DI
   call mpi_barrier(mpi_comm_world,mpierr)
   call descriptor_identification
   if(mpirank==0) then
       write(*,'(a)') 'DI done!'
       write(9,'(a)') 'DI done!'
   end if
end do

if(mpirank==0) then
 write(*,'(/a)') 'FCDI done !'
 write(9,'(/a)') 'FCDI done !'
 call system('rm CONTINUE')
end if

3001  continue

deallocate(nsample)
deallocate(ngroup)
deallocate(isconvex)
deallocate(pfdim)
deallocate(prop_y)
deallocate(psfeat)
deallocate(pfname)
deallocate(pvfeat)
deallocate(res)

call mpi_barrier(mpi_comm_world,mpierr)

if(mpirank==0) then
   etime_FCDI=mpi_wtime()
   write(9,'(/a)') '--------------------------------------------------------------------------------'
   write(9,'(a,f15.2)') 'Total wall-clock time (second): ',etime_FCDI-stime_FCDI
   write(9,'(/a/)') '                                               Have a nice day !    '
   close(9)
end if

call mpi_finalize(mpierr)

contains

subroutine prepare4FC
! prepare the response
integer i,j,k,l,ntmp
real*8 rtmp,fit(sum(nsample))
character linename1*100,linename2*100

if(iFCDI==1) then
  res=prop_y
else
  ! get the residual
  i=0
  do k=1,ntask
     i=i+1  ! the property ID
     write(linename1,'(a,i3.3,a,i3.3,a)') 'desc_',iFCDI-1,'d_p',i,'.dat'
     write(linename2,'(a,i3.3,a,i3.3,a)') 'res_',iFCDI-1,'d_p',i,'.dat'
     open(funit,file='desc_dat/'//trim(adjustl(linename1)),status='old')
     open(1,file='residual/'//trim(adjustl(linename2)),status='replace')
     read(funit,*)
     do l=1,nsample(k)
        read(funit,'(a)') line
        if (ptype==1) then
            read(line,*) ntmp,rtmp,fit(sum(nsample(:k-1))+l)
            write(1,'(e20.10)') prop_y(sum(nsample(:k-1))+l)-fit(sum(nsample(:k-1))+l)
        else if (ptype==2) then
            read(line,*) ntmp,res(sum(nsample(:k-1))+l)
            write(1,'(e20.10)') res(sum(nsample(:k-1))+l)
        end if
     end do
     close(funit)
     close(1)
  end do
  if (ptype==1) res=prop_y-fit
end if

end subroutine

subroutine prepare4DI
! prepare the union of subspaces
integer i,j,k,l
character linename*100
real*8 feat(sum(nsample),sum(subs_sis(:desc_dim))),rtmp

IF(nsis(iFCDI)==0) return

! space name file
do i=1,iFCDI
    write(linename,'(a,i3.3,a)') 'space_',i,'d.name'
    if(i==1) then
      call system('cd feature_space; cat '//trim(adjustl(linename))//' >Uspace.name')
    else
      call system('cd feature_space; cat '//trim(adjustl(linename))//' >>Uspace.name')
    end if
end do

! space data files
i=0
do k=1,ntask
    i=i+1
    ! previous Uspace
    if(iFCDI>1) then
        write(linename,'(a,i3.3,a)') 'Uspace_p',i,'.dat'
        open(funit,file='feature_space/'//trim(adjustl(linename)),status='old')
        if(ptype==1) then
           do l=1,nsample(k)
             read(funit,*) rtmp,feat(sum(nsample(:k-1))+l,:sum(nsis(:iFCDI-1)))
           end do
        else
           do l=1,nsample(k)
             read(funit,*) feat(sum(nsample(:k-1))+l,:sum(nsis(:iFCDI-1)))
           end do
        end if
        close(funit)
    end if

    ! this subspace
    write(linename,'(a,i3.3,a,i3.3,a)') 'space_',iFCDI,'d_p',i,'.dat'
    open(funit,file='feature_space/'//trim(adjustl(linename)),status='old')
    if(ptype==1) then
       do l=1,nsample(k)
         read(funit,*) rtmp,feat(sum(nsample(:k-1))+l,sum(nsis(:iFCDI-1))+1:sum(nsis(:iFCDI)))
       end do
    else
       do l=1,nsample(k)
         read(funit,*) feat(sum(nsample(:k-1))+l,sum(nsis(:iFCDI-1))+1:sum(nsis(:iFCDI)))
       end do
    end if
    close(funit)

    write(linename,'(a,i3.3,a)') 'Uspace_p',i,'.dat'
    ! create the new Uspace
2000 format(*(e20.10))

     open(funit,file='feature_space/'//trim(adjustl(linename)),status='replace')
     if(ptype==1) then
        do l=1,nsample(k)
         write(funit,2000) prop_y(sum(nsample(:k-1))+l),feat(sum(nsample(:k-1))+l,:sum(nsis(:iFCDI)))
        end do
     else
        do l=1,nsample(k)
         write(funit,2000) feat(sum(nsample(:k-1))+l,:sum(nsis(:iFCDI)))
        end do
     end if
     close(funit)
end do
end subroutine


subroutine writeCONTINUE(AA)
character AA*2
2005 format(*(i10))
   open(1234,file='CONTINUE',status='replace')
   write(1234,'(i2.2)') iFCDI
   write(1234,'(a)') AA
   write(1234,2005) nsis(:iFCDI)
   close(1234)
end subroutine

subroutine read_para_a
integer i,j,k,l,ioerr
character line_para*500        
logical in_readerr

!read parameters from SISSO.in
in_readerr=.true.
open(funit,file='SISSO.in',status='old')
do while(.true.)

   read(funit,'(a)',iostat=ioerr) line_para
   if(ioerr<0) exit

   if(index(line_para,'!')/=0) line_para(index(line_para,'!'):)=''
   i=index(line_para,'=')
   if(i>0) then
   select case (trim(adjustl(line_para(1:i-1))))
!--
!   case('calc')
!   read(line_para(i+1:),*,err=1001) calc
   case('restart')
   read(line_para(i+1:),*,err=1001) restart
   case('nsf')
   read(line_para(i+1:),*,err=1001) nsf
   case('ntask')
   read(line_para(i+1:),*,err=1001) ntask
   case('task_weighting')
   read(line_para(i+1:),*,err=1001) task_weighting
   case('nsample') 
   read(line_para(i+1:),'(a)',err=1001) nsample_line
   case('isconvex')
   read(line_para(i+1:),'(a)',err=1001) isconvex_line
   case('nvf')
   read(line_para(i+1:),*,err=1001) nvf
   case('vfsize')
   read(line_para(i+1:),*,err=1001) vfsize
   case('vf2sf')
   read(line_para(i+1:),*,err=1001) vf2sf
   case('desc_dim')
   read(line_para(i+1:),*,err=1001) desc_dim
!-
   case('dimclass')
     read(line_para(i+1:),'(a)',err=1001) dimclass
     ndimtype=0
     k=0
     do while (index(dimclass(k+1:),'(')>0)
       k=index(dimclass(k+1:),'(')+k
       ndimtype=ndimtype+1
     end do
   case('maxfval_lb')
   read(line_para(i+1:),*,err=1001) maxfval_lb
   case('maxfval_ub')
   read(line_para(i+1:),*,err=1001) maxfval_ub
   case('maxcomplexity')
   read(line_para(i+1:),*,err=1001) maxcomplexity
!--
   case('rung')
   read(line_para(i+1:),*,err=1001) rung
   case('npf_must')
   read(line_para(i+1:),*,err=1001) npf_must
   case('opset')
   if(index(line_para(i+1:),',')/=0) then
       read(line_para(i+1:),*,err=1001) opset(:rung)  ! multiple values
   else
       read(line_para(i+1:),*,err=1001) opset(1)  ! one value
       opset=opset(1)  ! let every set the same
   end if
!--
   case('subs_sis')
   if(index(line_para(i+1:),',')/=0) then
       read(line_para(i+1:),*,err=1001) subs_sis(:desc_dim) ! multiple values
   else 
       read(line_para(i+1:),*,err=1001) subs_sis(1) ! one value
       subs_sis=subs_sis(1)   ! let every subspace the same size
   end if
   case('ptype')
   read(line_para(i+1:),*,err=1001) ptype
   case('width')
   read(line_para(i+1:),*,err=1001) width
!--
   case('nm_output')
   read(line_para(i+1:),*,err=1001) nm_output
   case('metric')
   read(line_para(i+1:),*,err=1001) metric
!   case('CV_fold')
!   read(line_para(i+1:),*,err=1001) CV_fold
!   case('CV_repeat')
!   read(line_para(i+1:),*,err=1001) CV_repeat
   case('method')
   read(line_para(i+1:),*,err=1001) method
   case('fit_intercept')
   read(line_para(i+1:),*,err=1001) fit_intercept
   case('L1L0_size4L0')
   read(line_para(i+1:),*,err=1001) L1L0_size4L0
!--
   case('L1_max_iter')
   read(line_para(i+1:),*,err=1001) L1_max_iter
   case('L1_tole')
   read(line_para(i+1:),*,err=1001) L1_tole
   case('L1_nlambda')
   read(line_para(i+1:),*,err=1001) L1_nlambda
   case('L1_dens')
   read(line_para(i+1:),*,err=1001) L1_dens
   case('L1_minrmse')
   read(line_para(i+1:),*,err=1001) L1_minrmse
   case('L1_warm_start')
   read(line_para(i+1:),*,err=1001) L1_warm_start
   case('L1_weighted')
   read(line_para(i+1:),*,err=1001) L1_weighted
   case('L1_elastic')
   read(line_para(i+1:),*,err=1001) L1_elastic

   end select
   end if
end do
close(funit)

in_readerr=.false.
1001 if(in_readerr) stop 'Error when reading file "SISSO.in" !!!'

end subroutine


subroutine read_para_b
! read extra parameters
integer*8 i,j,k,kk,l,ll

! nsample
nsample=0
ngroup=0
isconvex=1
if(ptype==1) then
  read(nsample_line,*) nsample
else
  do ll=1,ntask
    i=index(nsample_line,'(')
    j=index(nsample_line,')')
    l=0
    do k=i,j
       if(nsample_line(k:k)==',') l=l+1
    end do
    read(nsample_line(i+1:j-1),*) ngroup(ll,1:l+1)
    ngroup(ll,1000)=l+1   ! record the total number of groups
    nsample(ll)=sum(ngroup(ll,1:l+1))
    nsample_line(:j)=''
  end do

  do ll=1,ntask
    i=index(isconvex_line,'(')
    j=index(isconvex_line,')')
    l=0
    do k=i,j
       if(isconvex_line(k:k)==',') l=l+1
    end do
    read(isconvex_line(i+1:j-1),*) isconvex(ll,1:l+1)
    isconvex(ll,1000)=l+1 
  end do

end if

! dimension
pfdim=0.d0   ! dimensionless for default
do ll=1,ndimtype
  i=index(dimclass,'(')
  j=index(dimclass,':')
  kk=index(dimclass,')')
  if(i>0 .and. j>0) then
    read(dimclass(i+1:j-1),*) k
    read(dimclass(j+1:kk-1),*) l
    pfdim(ll,k:l)=1.d0
    dimclass(:kk)=''
  end if
end do

end subroutine

subroutine read_data
integer*8 i,j,k,l,ll
logical dat_readerr,vfdat_readerr
character(len=lname) string_tmp(2+nsf+nvf)

!if(trim(adjustl(calc))=='FC' .or. trim(adjustl(calc))=='FCDI') then
    if(mpirank==0) write(9,'(a)') 'Reading data from train.dat ...'

    !read train.dat 
    dat_readerr=.true.
    open(funit,file='train.dat',status='old')
      read(funit,'(a)',err=1002) line
      call string_split(line,string_tmp,' ')
      if(ptype==1) then
         pfname=string_tmp(3:2+nsf)
      else
         pfname=string_tmp(2:1+nsf)
      end if
      do i=1,sum(nsample)
          read(funit,'(a)',err=1002) line
          line=adjustl(line)
          j=index(line,' ')
          line=line(j:)
          if(ptype==1) then
            read(line,*) prop_y(i),psfeat(i,:)
          else
            read(line,*) psfeat(i,:)   ! no y value in the train.dat file for classification
            prop_y(i)=0.d0    ! 0 denote unclassified
          end if
      end do
    close(funit)

    dat_readerr=.false.
    1002 if(dat_readerr) stop 'Error when reading file "train.dat" !!!'

    ! read train_vf.dat
    vfdat_readerr=.true.
    if(nvf>0) then
      if(mpirank==0) write(9,'(a)') 'Reading data from train_vf.dat ...'
      open(funit,file='train_vf.dat',status='old')
      read(funit,'(a)',err=1003) line   ! title line
      call string_split(line,pfname(nsf+1:),' ')  ! save vector-feature names
      do i=1,sum(nsample)
         read(funit,*,err=1003) (pvfeat(i,:,j),j=1,nvf)
      end do
      close(funit)
    end if

    vfdat_readerr=.false.
    1003 if(vfdat_readerr) stop 'FC: reading error from the file "train_vf.dat" !!!'
!end if
end subroutine


subroutine initialization
!calc='FCDI'               !'FCDI': Feature Construction & Descriptor Identification; 'FC': one-off FC; 'DI': one-off DI
restart=.false.           ! set .true. to continue a job that was stopped but not yet finished.
nsf= 1                    ! number of scalar features
nvf= 0                    ! number of vector features
ptype=1                   ! property type 1: continuous for regression,2:categorical for classification
ntask=1                   ! number of tasks (properties or maps) 1: single-task learning, >1: multi-task learning
vfsize= 0                 ! size of each vector feature (all vectors have the same size)
vf2sf= 'sum'              ! transforming vector to scalar features: sum,norm,min,max
width=1d-6                ! boundary tolerance (width) for classification 
task_weighting=1          ! 1: no weighting (tasks treated equally) 2: weighted by #sample_task_i/total_sample.

maxcomplexity=10          ! max feature complexity (number of operators in a feature)
npf_must=0                ! # of 'must selected' primary features with name labeled A, B, C, ... (see the User Guide)
maxfval_lb=1d-8           ! features having the max. abs. data value <maxfval_lb will not be selected
maxfval_ub=1d5            ! features having the max. abs. data value >maxfval_ub will not be selected
rung=1                    ! rung of the feature space to be constructed (times of applying the opset recursively)
subs_sis=-1                ! size of the SIS-selected (single) subspace for each descriptor dimension
opset=''                  ! operator sets for feature transformation
method='L0'               ! 'L1L0' or 'L0'
metric='RMSE'             ! metric for model selection: RMSE,MaxAE
fit_intercept=.true.      ! fit to a nonzero intercept (.true.) or force the intercept to zero (.false.)
!CV_fold=10               ! k-fold CV for each model: >=2
!CV_repeat=1              ! repeated k-fold CV
desc_dim=1                ! descriptors up to desc_dim dimension will be calculated
nm_output=100             ! number of models to be output (see files topxxx )

L1L0_size4L0=1            ! number of selected features by L1 for L0
L1_max_iter=1e6           ! max iteration for LASSO (given a lambda) to stop
L1_tole=1e-6              ! convergence criteria for LASSO to stop
L1_dens=120               ! density of lambda grid = number of points in [0.001*max,max]
L1_nlambda=1e3            ! max number of lambda points
L1_minrmse=1e-3           ! Min RMSE for the LASSO to stop
L1_warm_start=.true.      ! using previous solution for the next step
L1_weighted=.false.       ! weighted observations? (provide file prop.weight if yes)
nsis=0
end subroutine


subroutine output_para
!---------------------
! output parameters
!---------------------
2001   format(a,*(i8))
2002   format(*(f6.2))
2003   format(a,i3,a,*(i5))
2004   format(*(a))
   write(9,'(a)') 'Reading parameters from SISSO.in: '
   write(9,'(a)')  '--------------------------------------------------------------------------------'
!   write(9,'(2a)') 'calc: ',calc
   write(9,'(a,l6)') 'Restarts :',restart
   write(9,'(a,i8)') 'Descriptor dimension: ',desc_dim
   write(9,'(a,i3)') 'Property type:   ',ptype
   write(9,'(a,i8)')  'Total number of properties: ',ntask
   write(9,'(a,i8)') 'Task_weighting: ',task_weighting
   write(9,2001)  'Number of samples for each property: ',nsample
   if(ptype==2) then
     do i=1,ntask
      write(9,2003) 'Number of samples in each group of the property ',i,': ',ngroup(i,:ngroup(i,1000))
      write(9,2003) 'Convexity of the data domain of the property ',i,': ',isconvex(i,:isconvex(i,1000))
     end do
   write(9,'(a,f10.6)') 'Boundary tolerance (width) for classification: ',width
   end if

   write(9,'(a,i8)')  'Number of scalar features: ',nsf
   if(nvf>0) then
   write(9,'(a,i8)')  'Number of vector features: ',nvf
   write(9,'(a,i8)')  'Size of the vector features: ',vfsize
   write(9,'(a,a)')  'How to transform vectors to scalars? ',trim(vf2sf)
   end if
   write(9,'(a,i8)')  'Number of recursive calls for feature transformation (rung of the feature space): ',rung
   write(9,'(a,i8)')  'Max feature complexity (number of operators in a feature): ',maxcomplexity
   write(9,'(a,i8)') 'Number of dimension(unit)-type (for dimension analysis): ',ndimtype
   write(9,'(a)') 'Dimension type for each primary feature: '
   do i=1,nsf+nvf
     write(9,2002) pfdim(:,i)
   end do
!   write(9,'(a,i8)')  'number of primary features that must appear in each of the selected features: ',npf_must
   write(9,'(a,e15.5)') 'Lower bound of the max abs. data value for the selected features: ',maxfval_lb
   write(9,'(a,e15.5)') 'Upper bound of the max abs. data value for the selected features: ',maxfval_ub
   write(9,2001) 'Size of the SIS-selected (single) subspace : ',subs_sis(:desc_dim)
   write(9,2004)  'Operators for feature construction: ',(trim(opset(j)),' ',j=1,rung)

   if(trim(adjustl(method))=='L1L0') then
     write(9,'(a,i10)') 'Max iterations for LASSO (with given lambda) to stop: ',L1_max_iter
     write(9,'(a,e20.10)') 'Convergence criteria for LASSO: ',L1_tole
     write(9,'(a,i8)') 'Number of lambda trial: ',L1_nlambda
     write(9,'(a,i8)') 'Density of lambda points: ',L1_dens
     write(9,'(a,e20.10)') 'Minimal RMSE for LASSO to stop: ',L1_minrmse
     write(9,'(a,l6)') 'Weighted observations (if yes, provide file prop.weight)? ',L1_weighted
     write(9,'(a,l6)') 'Warm start?  ',L1_warm_start
     write(9,'(a,e20.10)') 'Elastic net: ',L1_elastic
   end if

   write(9,'(a,a)') 'Method for sparsification:  ',method
   if(trim(adjustl(method))=='L1L0') then
       write(9,'(a,i8)') 'Number of screened features by L1 for L0 in L1L0:', L1L0_size4L0
   end if
   write(9,'(a,i8)') 'Number of the top ranked models to output: ',nm_output
   if(ptype==1) then
     write(9,'(a,l6)') 'Fitting intercept? ',fit_intercept
     write(9,'(a,a)')  'Metric for model selection: ',trim(metric)
!     write(9,'(a,i8)') 'Fold of the k-fold CV (descriptor fixed): ',CV_fold
!     write(9,'(a,i8)') 'Number of repeat for the k-fold CV: ',CV_repeat
   end if
   write(9,'(a)') '--------------------------------------------------------------------------------'
end subroutine

end program
