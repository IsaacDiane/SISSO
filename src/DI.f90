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


module DI
! descriptor identification
!-------------------------------------------------------------

use var_global
use libsisso
integer dim_DI

contains




subroutine descriptor_identification
real*8,allocatable:: xinput(:,:,:),yinput(:,:),beta(:,:),beta_init(:,:),coeff(:,:),xprime(:,:,:),&
        xdprime(:,:,:),xmean(:,:),norm_xprime(:,:),yprime(:,:),prod_xty(:,:),prod_xtx(:,:,:),lassormse(:),&
        ymean(:),intercept(:),weight(:,:) , xyinput(:,:) ,yres(:,:)
real*8  lambda,lambda_max,alpha,L1_minrmse,totalrmse
integer run_iter,i,j,k,l,ll,nf,maxns,ntry,nactive,newnactive
integer,allocatable:: idf(:),activeset(:),ncol(:)      ,fid(:) ,newactiveset(:)
character line*500 , tmp*500 ,tmp1*500,tmp2*500,tmp3*500
character,allocatable:: fname(:)*200
logical isnew,dat_readerr
real*8 stime_DI,etime_DI
character(1000) cmd


if(mpirank==0) stime_DI=mpi_wtime()
maxns=maxval(nsample)
!if(trim(adjustl(calc))=='FCDI') then
  dim_DI=iFCDI
!else
!  dim_DI=desc_dim
!end if
!
!if(mpirank==0 .and. trim(adjustl(calc))/='FCDI') then
!    call system('rm -rf desc_dat')
!    call system('rm -rf models')
!    call system('mkdir desc_dat models')
!end if

!--------------------------
allocate(xinput(maxns,fs_size_DI,ntask))
allocate(yinput(maxns,ntask))
allocate(fname(fs_size_DI))
allocate(weight(maxns,ntask))
allocate(activeset(fs_size_L0))

!------------------------
! job allocation
!------------------------
allocate(ncol(mpisize))
mpii=fs_size_DI/mpisize
mpij=mod(fs_size_DI,mpisize)
ncol(1)=mpii
do mpin=1,mpisize-1
if(mpin<=mpij) then
ncol(1+mpin)=mpii+1
else
ncol(1+mpin)=mpii
end if
end do

!-----------------------
! data read in
!-----------------------

dat_readerr=.true.

yinput=0
xinput=0
do i=1,ntask

!  if(trim(adjustl(calc))=='FCDI') then
    write(line,'(a,i3.3,a)') 'Uspace_p',i,'.dat'
!  else
!    write(line,'(a,i3.3,a)') 'space_p',i,'.dat'
!  end if

  if(mpirank==0) then
  open(funit,file='feature_space/'//trim(adjustl(line)),status='old')
   if(ptype==1) then
      do j=1,nsample(i)
         read(funit,*,err=334) yinput(j,i),xinput(j,:,i)
      end do
   else
      do j=1,nsample(i)
         read(funit,*,err=334) xinput(j,:,i)
         yinput(j,i)=0.d0  
      end do
   end if
   close(funit)
   end if

   call mpi_bcast(yinput,maxns*ntask,mpi_double_precision,0,mpi_comm_world,mpierr)
   call mpi_bcast(xinput,maxns*fs_size_DI*ntask,mpi_double_precision,0,mpi_comm_world,mpierr)

end do

dat_readerr=.false.
334 if(dat_readerr) stop 'Error when reading the space data files !!!'


if(mpirank==0) then
!  if (trim(adjustl(calc))=='FCDI') then
    open(funit,file='feature_space/Uspace.name',status='old')
!  else
!    open(funit,file='feature_space/space.name',status='old')
!  end if
  
  do i=1,fs_size_DI
  read(funit,'(a)') line
  line=trim(adjustl(line))
  fname(i)=line(1:index(line,' '))
  end do
  close(funit)
end if

  call mpi_bcast(fname,fs_size_DI*200,mpi_character,0,mpi_comm_world,mpierr)


weight=1.0
if(task_weighting==1) then ! tasks treated equally
  weight=1.0/float(ntask)
else if(task_weighting==2) then ! tasks weighted by #sample_task_i/total_sample
  do i=1,ntask
     weight(:,i)=float(nsample(i))/float(sum(nsample))
  end do
end if

if(L1_weighted) then
open(funit,file='lasso.weight',status='old')
read(funit,*) ! title line
do i=1,ntask
  do j=1,nsample(i)
    read(funit,*) weight(j,i)
  end do
end do
close(funit)
end if


if(fs_size_L0>fs_size_DI) stop "Error: fs_size_L0 must not larger than fs_size_DI ! "

!-----------------------------------------------------
! MODEL SELECTION (L0 or L1L0)
!-----------------------------------------------------

if(trim(adjustl(method))=='L1L0' .and. fs_size_DI/=fs_size_L0 .and. ptype==1) then
    !----------------
    ! L1 of the L1L0
    ! see J. Friedman, T. Hastie, and R. Tibshirani 2010,"Regularization Paths for Generalized Linear Models via CD"
    ! "J. Friedman, T. Hastie, and R. Tibshirani, 2010 "A note on the group lasso and a sparse group lasso"
    !----------------
    allocate(xprime(maxns,fs_size_DI,ntask))
    allocate(xdprime(maxns,fs_size_DI,ntask))
    allocate(xmean(fs_size_DI,ntask))
    allocate(norm_xprime(fs_size_DI,ntask))
    allocate(prod_xtx(fs_size_DI,ncol(mpirank+1),ntask))
    allocate(intercept(ntask))
    allocate(beta(fs_size_DI,ntask)) 
    allocate(beta_init(fs_size_DI,ntask))
    allocate(yprime(maxns,ntask))
    allocate(prod_xty(fs_size_DI,ntask))
    allocate(lassormse(ntask))
    allocate(ymean(ntask))
    
    ! initialization for L1
    xprime=0
    xdprime=0
    xmean=0
    norm_xprime=0
    prod_xtx=0
    beta=0
    beta_init=0.0
    yprime=0
    prod_xty=0
    lassormse=0
    ymean=0
    
    !-------------------------------------------------------------------------------------------------------
    ! standardize and precompute the data for lasso
    ! transform y=a+xb into y=xb; y'=y-ymean; x'(:,j)=x(:,j)-xmean(j); 
    ! x(:,j)''=x(:,j)'/nomr(x'(j)); a=ymean-sum(xmean*b); b'=b*norm(x')
    ! after solving b', do b'->b and calculate a to get y=a+bx
    ! (observation) weighting is applied to square error, not the training property.
    ! see "J. Friedman, T. Hastie, and R. Tibshirani, 2010 "A note on the group lasso and a sparse group lasso"
    !--------------------------------------------------------------------------------------------------------
    if(mpirank==0) write(9,'(a)') 'data standardizing ... '
    !yprime
    do i=1,ntask
    ymean(i)=sum(yinput(:nsample(i),i))/nsample(i)
    yprime(:nsample(i),i)=yinput(:nsample(i),i)-ymean(i)
    end do
    
    do i=1,ntask
       !xprime and xdprime
       do j=1,fs_size_DI
         xmean(j,i)=sum(xinput(:nsample(i),j,i))/nsample(i)
         xprime(:nsample(i),j,i)=xinput(:nsample(i),j,i)-xmean(j,i)
         norm_xprime(j,i)=sqrt(sum(xprime(:nsample(i),j,i)**2))
         if(abs(norm_xprime(j,i))<1d-10) then
         if(mpirank==0) print *, 'Error: norm of feature ',j,' of task ',i,' is zero'
         stop
         end if
         xdprime(:nsample(i),j,i)=xprime(:nsample(i),j,i)/norm_xprime(j,i)
       end do
       !xty
       prod_xty(:,i)=matmul(transpose(xdprime(:nsample(i),:,i)),weight(:nsample(i),i)*yprime(:nsample(i),i))
       !xtx=(xtx)t !prod_xtx(mpii,:)=prod_xtx(:,mpii)
       do mpii=1,ncol(mpirank+1)
       prod_xtx(:,mpii,i)=matmul(xdprime(:nsample(i),mpii+sum(ncol(1:mpirank)),i)*weight(:nsample(i),i),&
                                          xdprime(:nsample(i),:,i))
       end do
    
    end do
    
    !--------------------------------------------------------------------------------------------------------------
    ! get lambda_max
    !---------------------------------------------------------------------------------------------------------------
    lambda_max=0
    do j=1,fs_size_DI
    lambda=sqrt(sum(prod_xty(j,:)**2))
    if(lambda>lambda_max) lambda_max=lambda
    end do
    
    if(mpirank==0) then
    write(9,'(a)') 'feature selection by multi-task lasso starts ... '
    end if
    
    !----------------------------------------
    ! (Elastic net) H. Zou, and T. Hastie, J. R. Statist. Soc. B 67, 301 (2005).
    ! L1_elastic=1 is back to lasso (Eq. 14)
    !----------------------------------------
    !if(L1_elastic<1.0) then
    !prod_xtx=L1_elastic*prod_xtx
    !do j=1,fs_size_DI
    !prod_xtx(j,j,:)=prod_xtx(j,j,:)+(1-L1_elastic)
    !end do
    !end if
    
    !---------------------------------------------------------------------------
    ! Calculating lasso path with decreasing lambdas
    !---------------------------------------------------------------------------
    
    !counting the total size of the active set
    nactive=0
    ! iteration starts here
    do ntry=1,L1_nlambda
        ! create lambda sequence
        ! max and min in log space: max=log10(lambda_max),min=log10(0.001*lambda_max)
        ! density, i.e.: 100 points, interval=(max-min)/100=0.03
        ! lambda_i=10^(max-0.03*(i-1))
        lambda=10**(log10(lambda_max)-3.0/L1_dens*(ntry-1))
    
        ! call mtlasso
        call mtlasso_mpi(prod_xty,prod_xtx,lambda,L1_max_iter,L1_tole,beta_init,run_iter,beta,nf,ncol)
        
        ! lasso rmse
        do i=1,ntask
         lassormse(i)=sqrt(sum(weight(:nsample(i),i)*(yprime(:nsample(i),i)-matmul(xdprime(:nsample(i),:,i),&
                       beta(:,i)))**2)/nsample(i))  ! RMSE
        end do
        totalrmse=sqrt(sum(lassormse**2))  ! the 'weight' already considered the averaging.
    
        ! L1_warm_start
        if(L1_warm_start) beta_init=beta
        
        ! intercept and beta
        do i=1,ntask
          intercept(i)=ymean(i)-sum(xmean(:,i)*beta(:,i)/norm_xprime(:,i))
        end do   
                       
        ! store the coeff. and id of features of this active set
        allocate(coeff(nf,ntask))
        allocate(idf(nf))
        coeff=0
        idf=0
        k=0
        do j=1,fs_size_DI
          if(maxval(abs(beta(j,:)))>1d-10) then
           k=k+1
           idf(k)=j
           coeff(k,:)=beta(j,:)
          end if
        end do
        if(k/=nf .and. mpirank==0 ) stop 'ID of selected features not correctly identified !'
        
        ! add to the total active set
        isnew=.true.  
        do k=1,nf
          if(any(idf(k)==activeset(:nactive))) isnew=.false.
          if(isnew) then
             nactive=nactive+1
             activeset(nactive)=idf(k)
          end if
          isnew=.true.
          if(nactive==fs_size_L0) exit
        end do
        
        ! output information of this lambda
        if(mpirank==0) then
        write(9,'(/)') 
        write(9,'(a,i5)') 'Try: ',ntry
        write(9,'(a)') '----------------'
        write(9,'(a30,e20.10)')  'Lambda: ', lambda
        write(9,'(a30,i10)')   'Number of iteration: ',run_iter
2004    format(a30,*(f10.6))
        write(9,2004)  ' Total LASSO RMSE: ', totalrmse
        write(9,2004)  ' LASSO RMSE for each property: ', lassormse
        write(9,'(a30,i6)')   'Size of this active set: ',nf
2005    format(a30,*(i8))
        if(nf/=0) write(9,2005)   'This active set: ',idf
        if(nf/=0) then
2006    format(a25,i3.3,a2,*(e20.10))
        do i=1,ntask
        write(9,2006) 'LASSO Coeff._',i,': ', coeff(:,i)
        end do
        end if
        write(9,'(a30,i6)') 'Size of the tot act. set: ',nactive
2007    format(a30,*(i8))
        if(nactive/=0) write(9,2007) 'Total active set: ',(activeset(j),j=1,nactive)
        end if
        deallocate(coeff)
        deallocate(idf)
        
        ! exit
        if(nactive>=fs_size_L0) then
        if(mpirank==0) write(9,'(/a,i3)') 'Total number of selected features >= ',fs_size_L0
        exit
        else if (nactive==fs_size_DI) then
        if(mpirank==0) write(9,'(/a)') 'The whole feature space is already selected!'
        exit
        else if (ntry==L1_nlambda) then
        if(mpirank==0) write(9,'(/a)') 'Number of lambda trials hits the max !'
        exit
        else if (maxval(lassormse)<L1_minrmse) then
        if(mpirank==0) write(9,'(/a)') 'RMSE is already smaller than the criterion!'
        exit
        end if
    
    end do
    deallocate(prod_xty)
    deallocate(prod_xtx)
    deallocate(ncol)
    deallocate(beta)
    deallocate(beta_init)
    deallocate(xprime)
    deallocate(xdprime)
    deallocate(xmean)
    deallocate(yprime)
    deallocate(intercept)
    deallocate(norm_xprime)
    deallocate(ymean)
    deallocate(lassormse)
    if(mpirank==0) write(9,'(a)') ' L1 finished ! '
    !---------------
    ! L0 of the L1L0
    !---------------
     call model(xinput,yinput,fname,nactive,activeset)
 
else if (trim(adjustl(method))=='L0' .or. fs_size_DI==fs_size_L0) then
    !--------
    ! L0
    !--------
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    allocate(fid (size(xinput,2)+1))
    do fidi = 1,size(fid,1)
    	fid(fidi)=fidi-1
    end do
    allocate(xyinput(size(xinput,1),size(xinput,2)+1))
    allocate(yres(size(yinput,1),1))
    if (iFCDI == 1) then
    	yres(:,1)=yinput(:,1)
    else
    	write(tmp3,'(a,i3.3,a,a)') 'res_',iFCDI-1,'d_p001','.dat'
    	open(4395,file='residual/'//trim(adjustl(tmp3)),status='old')
    	read(4395,*) yres(:,1)
    end if
    xyinput(1:,1)=yres(:,1)
    xyinput(1:,2:)=xinput(:,:,1)
    open(4396,file='tempfile',status='replace')
3333  format((e17.10))
5555  format((e16.10))
4444  format((a))
      do i=1 ,size(fid,1)-1
      	 write( tmp , '(i9.9)') fid(i)
      	 write(4396,4444,advance='no') adjustl(trim(tmp))//Adjustl(trim(','))
      end do
      write( tmp , '(i9.9)') fid(size(fid,1))
      write(4396,4444) adjustr(adjustl(trim(tmp)))
      do i=1,size(xyinput,1)
          do j=1,size(xyinput,2)-1
          	if (xyinput(i,j) <0)then 
          		write(tmp,3333) xyinput(i,j)
          	else
          		write(tmp,5555) xyinput(i,j)
          	end if 
          	write(4396,'(a)',advance='no') adjustl(trim(tmp))//Adjustl(trim(','))
          end do
          write( tmp , 3333) xyinput(i,size(xyinput,2))
      	  write(4396,'(a)') adjustl(trim(tmp))
      end do
    close(4396)
    write(tmp,'(i5)') size(xyinput,1)
    write(tmp1,'(i7)') size(xyinput,2)-1
    newnactive=floor(0.1*fs_size_L0)
    write(tmp2,'(i5)') newnactive/dim_DI
    !write(tmp2,'(i5)') 400
    if (dim_DI == 1) then
    cmd = './mrmr -i tempfile -s '&
    		//adjustl(trim(tmp))//' -v '//adjustl(trim(tmp1))&
    		//' -n '//adjustl(trim(tmp2))//' -t 1 > log'
    else 
    cmd='./mrmr -i tempfile -s '&
    		//adjustl(trim(tmp))//' -v '//adjustl(trim(tmp1))&
    		//' -n '//adjustl(trim(tmp2))//' -t 1 >> log'
    end if 
    write(*,*) trim(cmd)
    call system(trim(cmd))
    nactive=fs_size_L0
    
    allocate(newactiveset(newnactive))
    open(4397,file='log',status='old')
    	read(4397,*) newactiveset(:)
    close(4397)
    do i=1,fs_size_L0
       activeset(i)=i
    end do
    if(ptype==1) then
     call model(xinput,yinput,fname,newnactive,newactiveset)
    else if (ptype==2) then
     call model2(xinput,fname,nactive,activeset)
    end if
end if
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

! release space 
!--------------------
deallocate(xinput)
deallocate(yinput)
deallocate(fname)
deallocate(activeset)
deallocate(weight)
deallocate(newactiveset)
deallocate(fid)
deallocate(xyinput)

call mpi_barrier(mpi_comm_world,mpierr)
if(mpirank==0) then
  etime_DI=mpi_wtime()
  write(9,'(a,f15.2)') 'Wall-clock time (second) for this DI: ',etime_DI-stime_DI
end if

end subroutine


subroutine model(x,y,fname,nactive,activeset)
integer nactive,activeset(:),i,j,k,l,loc(1),ii(dim_DI),idimen,select_model(max(nm_output,1),dim_DI),&
        mID(max(nm_output,1),dim_DI)!,random(maxval(nsample),ntask,CV_repeat)
integer*8 totalm,bigm,nall,nrecord,nupper,nlower
real*8  x(:,:,:),y(:,:),tmp,tmp_LS,tmp2_LS,yfit,wrmse(ntask),LSrmse(ntask),LSmaxae(ntask),&
beta(dim_DI,ntask),intercept(ntask),select_LS(max(nm_output,1)),select_LSmaxae(max(nm_output,1)),&
select_coeff(max(nm_output,1),dim_DI+1,ntask),mscore(max(nm_output,1),2),select_metric(max(nm_output,1)),&
mcoeff(max(nm_output,1),dim_DI+1,ntask)
!select_CV(max(nm_output,1)),select_CVmaxae(max(nm_output,1)),tmp_CV,tmp2_CV,CVrmse(ntask),CVmaxae(ntask)
character fname(:)*200,line_name*100
logical isgood
integer*8 njob(mpisize)
real*8 mpicollect(mpisize)
real   progress
! model scores: RMSE,MaxAE,CV_RMSE,CV_MaxAE

if(nm_output<1) nm_output=1


if(mpirank==0) then
write(9,'(a)') 'L0 starts ...'
end if

! generation of random order for repeated k-fold CV
!do k=1,CV_repeat  
! do i=1,ntask
!  call rand_order(random(:nsample(i),i,k))
! end do
!end do

do idimen=1,dim_DI

   progress=0.2

   if(idimen<dim_DI) cycle ! .and. trim(adjustl(calc))=='FCDI') cycle

   ! job assignment for each CPU
   nall=1
   do mpii=1,idimen
      nall=nall*(nactive-mpii+1)/mpii
   end do
   if(nactive==idimen) nall=1
   njob=nall/mpisize

   mpij=mod(nall,int8(mpisize))
   do mpii=1,mpisize-1
     if(mpii<=mpij) njob(mpii+1)=njob(mpii+1)+1   
   end do

   ! initialization   
   select_LS=10*maxval(abs(y))
   select_LSmaxae=10*maxval(abs(y))
!   select_CV=10*maxval(abs(y))
!   select_CVmaxae=10*maxval(abs(y))
   totalm=0

! get the best nm_output models on each CPU core
   nrecord=0
   do k=1,nactive   ! features
      ii(1)=k   ! d1

      do j=2,idimen   ! d2, ..., d_idimen
        ii(j)=ii(j-1)+1   ! d1=k, d2=k+1,d3=k+2,...
      end do      

      nlower=sum(njob(:mpirank))+1
      nupper=sum(njob(:mpirank+1))
      123 continue 
      nrecord=nrecord+1
      if( nrecord< nlower) goto 124
      if( nrecord> nupper) exit

      if(float(nrecord-nlower+1)/float(njob(mpirank+1))>=progress) then
        write(*,'(a,i4,a,i4,a,f6.1,a)') 'dimension=',idimen,'    mpirank= ',mpirank,'    progress =',progress*100,'%'
        progress=progress+0.2
      end if

      !  LS and CV of this model
      if ( trim(adjustl(metric))=='RMSE' .or. trim(adjustl(metric))=='MaxAE') then
         do i=1,ntask
         if(fit_intercept) then
         call orth_de(x(:nsample(i),[activeset(ii(:idimen))],i),y(:nsample(i),i),intercept(i),beta(:idimen,i),LSrmse(i))
         else
         call orth_de_nointercept(x(:nsample(i),[activeset(ii(:idimen))],i),y(:nsample(i),i),beta(:idimen,i),LSrmse(i))
         intercept(i)=0.d0
         end if
         if(isnan(LSrmse(i))) then
            LSrmse(i)=sum(abs(y(:nsample(i),i)))
            intercept(i)=0.d0
            beta(:idimen,i)=0.d0
         end if
         LSmaxae(i)= &
          maxval(abs(y(:nsample(i),i)-(intercept(i)+matmul(x(:nsample(i),[activeset(ii(:idimen))],i),beta(:idimen,i)))))
         end do

         if(task_weighting==1) then
            tmp_LS=sqrt(sum(LSrmse**2)/ntask)  !overall error
         else if(task_weighting==2) then
            tmp_LS=sqrt(sum((LSrmse**2)*nsample)/sum(nsample))
         end if
         tmp2_LS=maxval(LSmaxae)        ! max(maxAE)

    !  else if ( trim(adjustl(metric))=='CV_RMSE' .or.  trim(adjustl(metric))=='CV_MaxAE') then
    !     do i=1,ntask
    !      CVrmse(i)=0.0
    !      CVmaxae(i)=0.0
    !      do j=1,CV_repeat
    !     call foldCV(x(:nsample(i),[activeset(ii(:idimen))],i),y(:nsample(i),i),random(:nsample(i),i,j),tmp_CV,tmp2_CV)
    !     CVrmse(i)=CVrmse(i)+tmp_CV**2  ! quadratic sum
    !     CVmaxae(i)=CVmaxae(i)+tmp2_CV**2
    !      end do
    !     end do
    !     tmp_CV=sqrt(sum(CVrmse)/CV_repeat/ntask)  ! quadratic mean
    !     tmp2_CV=sqrt(sum(CVmaxae)/CV_repeat/ntask)
      end if
    
      isgood=.false.
      if ( trim(adjustl(metric))=='RMSE' .and. any(tmp_LS <select_LS)) then
         isgood = .true.
         loc=maxloc(select_LS)
      else if ( trim(adjustl(metric))=='MaxAE' .and. any(tmp2_ls <select_LSmaxae)) then
         isgood = .true.
         loc=maxloc(select_LSmaxae)
   !   else if ( trim(adjustl(metric))=='CV_RMSE' .and. any(tmp_CV <select_CV)) then
   !      isgood = .true.
   !      loc=maxloc(select_CV)
   !   else if ( trim(adjustl(metric))=='CV_MaxAE' .and. any(tmp2_CV <select_CVmaxae)) then
   !      isgood = .true.
   !      loc=maxloc(select_CVmaxae)
      end if

      ! store good models with best RMSE
      if (isgood) then
         totalm=totalm+1
         if ( trim(adjustl(metric))=='RMSE' .or. trim(adjustl(metric))=='MaxAE') then
           select_LS(loc(1))=tmp_LS
           select_LSmaxae(loc(1))=tmp2_LS
       !  else if (trim(adjustl(metric))=='CV_RMSE' .or. trim(adjustl(metric))=='CV_MaxAE') then
       !    select_CV(loc(1))=tmp_CV
       !    select_CVmaxae(loc(1))=tmp2_CV
         end if
         select_model(loc(1),:idimen)=activeset(ii(:idimen))
         do i=1,ntask
             select_coeff(loc(1),1,i)=intercept(i)
             select_coeff(loc(1),2:idimen+1,i)=beta(:idimen,i)
         end do
      end if

      124 continue
      ! update the models(123,124,125,134,135,145,234,...)
      if(idimen==1) cycle
      ii(idimen)=ii(idimen)+1  ! add 1 for the highest dimension

      do j=idimen,3,-1
        if(ii(j)> (nactive-(idimen-j)) ) ii(j-1)=ii(j-1)+1 
      end do
      do j=3,idimen
        if(ii(j)> (nactive-idimen+j) ) ii(j)=ii(j-1)+1
      end do

      if(ii(2)>(nactive-(idimen-2)))  cycle

      goto 123
   end do

! calculate all errors of the nm_output model
!   do k=1,min(int8(nm_output),totalm)
!      if ( trim(adjustl(metric))/='RMSE' .and. trim(adjustl(metric))/='MaxAE') then
!         do i=1,ntask
!        if(fit_intercept) then
!        call orth_de(x(:nsample(i),[select_model(k,:idimen)],i),y(:nsample(i),i),intercept(i),beta(:idimen,i),LSrmse(i))
!        else
!        call orth_de_nointercept(x(:nsample(i),[select_model(k,:idimen)],i),y(:nsample(i),i),beta(:idimen,i),LSrmse(i))
!        intercept(i)=0.d0
!        end if
!         if(isnan(LSrmse(i))) then
!            LSrmse(i)=sum(abs(y(:nsample(i),i)))
!            intercept(i)=0.d0
!            beta(:idimen,i)=0.d0
!         end if
!          LSmaxae(i)= &
!         maxval(abs(y(:nsample(i),i)-(intercept(i)+matmul(x(:nsample(i),[select_model(k,:idimen)],i),beta(:idimen,i)))))
!         end do
!
!         if(task_weighting==1) then  ! tasks are treated equally
!            select_LS(k)=sqrt(sum(LSrmse**2)/ntask)  !overall error
!         else if(task_weighting==2) then  ! weighted by sample size
!            select_LS(k)=sqrt(sum((LSrmse**2)*nsample)/sum(nsample))
!         end if
!         select_LSmaxae(k)=maxval(LSmaxae)        ! max(maxAE)
!
    !  else if ( trim(adjustl(metric))/='CV_RMSE' .and.  trim(adjustl(metric))/='CV_MaxAE') then
    !     do i=1,ntask
    !      CVrmse(i)=0.0
    !      CVmaxae(i)=0.0
    !      do j=1,CV_repeat
    !     call foldCV(x(:nsample(i),[select_model(k,:idimen)],i),y(:nsample(i),i),random(:nsample(i),i,j),tmp_CV,tmp2_CV)
    !       CVrmse(i)=CVrmse(i)+tmp_CV**2  ! total sqaured error
    !       CVmaxae(i)=CVmaxae(i)+tmp2_CV**2
    !      end do
    !     end do
    !     select_CV(k)=sqrt(sum(CVrmse)/CV_repeat/ntask)  ! overall CV RMSE
    !     select_CVmaxae(k)=sqrt(sum(CVmaxae)/CV_repeat/ntask)
!      end if
!   end do


! collecting the best models
! select_model,select_LS,select_LSmaxae,select_CV,select_CVmaxae,mID,mscore(RMSE,MaxAE,CV_RMSE,CV_MaxAE)
   if(mpirank>0) then
     call mpi_send(totalm,1,mpi_integer8,0,1,mpi_comm_world,status,mpierr)
   else
     do i=1,mpisize-1
       call mpi_recv(bigm,1,mpi_integer8,i,1,mpi_comm_world,status,mpierr)
       totalm=totalm+bigm
     end do
   end if
   call mpi_bcast(totalm,1,mpi_integer8,0,mpi_comm_world,mpierr)

   if(trim(adjustl(metric))=='RMSE') then
     select_metric=select_LS
   else if (trim(adjustl(metric))=='MaxAE') then
     select_metric=select_LSmaxae     
!   else if (trim(adjustl(metric))=='CV_RMSE') then
!     select_metric=select_CV
!   else if (trim(adjustl(metric))=='CV_MaxAE') then
!     select_metric=select_CVmaxae
   end if

   do j=1,min(int8(nm_output),totalm)
      loc=minloc(select_metric)
      k=loc(1)
      if(mpirank>0) then
        call mpi_send(select_metric(loc(1)),1,mpi_double_precision,0,1,mpi_comm_world,status,mpierr)
      else
        mpicollect(1)=select_metric(loc(1))
        do i=1,mpisize-1
          call mpi_recv(mpicollect(i+1),1,mpi_double_precision,i,1,mpi_comm_world,status,mpierr)
        end do
        loc=minloc(mpicollect)
      end if
      call mpi_bcast(loc(1),1,mpi_integer,0,mpi_comm_world,mpierr)

      if(mpirank==loc(1)-1) then
        mID(j,:idimen)=select_model(k,:idimen)
        mcoeff(j,:idimen+1,:)=select_coeff(k,:idimen+1,:)
        mscore(j,:2)=(/select_LS(k),select_LSmaxae(k)/)
        select_metric(k)=10*maxval(abs(y))
      end if
      call mpi_bcast(mID(j,:idimen),idimen,mpi_integer,loc(1)-1,mpi_comm_world,mpierr)
      call mpi_bcast(mscore(j,:2),2,mpi_double_precision,loc(1)-1,mpi_comm_world,mpierr)
      call mpi_bcast(mcoeff(j,:idimen+1,:),(idimen+1)*ntask,mpi_double_precision,loc(1)-1,mpi_comm_world,mpierr)
   end do
 

   if(mpirank==0) then
      ! LSRMSE, LSmaxae, CVRMSE,CVmaxae of the best model
      do i=1,ntask
        ! LS
        if(fit_intercept) then
           call orth_de(x(:nsample(i),[mID(1,:idimen)],i),y(:nsample(i),i),intercept(i),beta(:idimen,i),LSrmse(i))
        else
           call orth_de_nointercept(x(:nsample(i),[mID(1,:idimen)],i),y(:nsample(i),i),beta(:idimen,i),LSrmse(i))
           intercept(i)=0.d0
        end if
         if(isnan(LSrmse(i))) then
            LSrmse(i)=sum(abs(y(:nsample(i),i)))
            intercept(i)=0.d0
            beta(:idimen,i)=0.d0
         end if
         LSmaxae(i)= &
           maxval(abs(y(:nsample(i),i)-(intercept(i)+matmul(x(:nsample(i),[mID(1,:idimen)],i),beta(:idimen,i)))))
        ! CV
      !  CVrmse(i)=0.0
      !  CVmaxae(i)=0.0
      !  do k=1,CV_repeat
      !    call foldCV(x(:nsample(i),[mID(1,:idimen)],i),y(:nsample(i),i),random(:nsample(i),i,k),tmp_CV,tmp2_CV)
      !    CVrmse(i)=CVrmse(i)+tmp_CV**2 ! sum of RMSE**2
      !    CVmaxae(i)=CVmaxae(i)+tmp2_CV**2
      !  end do
      end do
     ! CVrmse=sqrt(CVrmse/CV_repeat) ! average over repeated CV
     ! CVmaxae=sqrt(CVmaxae/CV_repeat)   ! average over repeated CV

      call writeout(idimen,mID(1,:idimen),LSrmse,LSmaxae,beta,intercept,x,y,fname)
!      call writeout(idimen,mID(1,:idimen),LSrmse,LSmaxae,beta,intercept,x,y,fname,CVrmse,CVmaxae)

      write(line_name,'(a,i4.4,a,i3.3,a)') 'top',min(int8(nm_output),totalm),'_',idimen,'d'
      open(funit,file='models/'//trim(adjustl(line_name)),status='replace')
      write(funit,'(4a12)') 'Rank','RMSE','MaxAE','Feature_ID'
!      write(111,'(6a12)') 'Rank','RMSE','MaxAE','CV_RMSE','CV_maxAE','Feature_ID'
2008  format(i12,2f12.6,a,*(i8))
      do i=1,min(int8(nm_output),totalm)
        write(funit,2008,advance='no') i,mscore(i,:),'  (',mID(i,:idimen)
        write(funit,'(a)') ')'
      end do
      close(funit)

      write(line_name,'(a,i4.4,a,i3.3,a)') 'top',min(int8(nm_output),totalm),'_',idimen,'d_coeff'
      open(funit,file='models/'//trim(adjustl(line_name)),status='replace')
      write(funit,'(a)') 'Model_ID, [(c_i,i=0,n)_j,j=1,ntask]'
20081 format(i12,*(e20.10))
      do i=1,min(int8(nm_output),totalm)
        write(funit,20081) i,(mcoeff(i,:idimen+1,j),j=1,ntask)
      end do
      close(funit)

   end if

end do

call mpi_barrier(mpi_comm_world,mpierr)
end subroutine


subroutine writeout(idimen,id,LSrmse,LSmaxae,betamin,interceptmin,x,y,fname)
!subroutine writeout(idimen,id,LSrmse,LSmaxae,betamin,interceptmin,x,y,fname,CVrmse,CVmaxae)
integer idimen,i,j,id(:),k
real*8 LSrmse(:),LSmaxae(:),betamin(:,:),interceptmin(:),x(:,:,:),y(:,:),yfit!,CVrmse(:),CVmaxae(:)
character fname(:)*200,line_name*100

if(idimen==desc_dim) then ! .and. trim(adjustl(calc))=='FCDI') then
  write(9,'(/a)')  'Final model/descriptor to report'
else if(idimen<desc_dim) then ! .and. trim(adjustl(calc))=='FCDI') then
  write(9,'(/a)')  'Model/descriptor for generating residual:'
!else if(trim(adjustl(calc))=='DI') then
!  write(9,'(/a)')  'Model/descriptor to report'
end if
  write(9,'(a)')'================================================================================'
write(9,'(i3,a)') idimen,'D descriptor (model): '

if(task_weighting==1) then  ! tasks are treated equally
   write(9,'(a,2f10.6)')  'Total RMSE,MaxAE: ',sqrt(sum(LSrmse**2)/ntask),maxval(LSmaxae)
else if(task_weighting==2) then  ! weighted by sample size
   write(9,'(a,2f10.6)')  'Total RMSE,MaxAE: ',sqrt(sum((LSrmse**2)*nsample)/sum(nsample)),maxval(LSmaxae)
end if
!,sqrt(sum(CVrmse**2)/ntask),sqrt(sum(CVmaxae**2)/ntask)

write(9,'(a)')  '@@@descriptor: '
do i=1,idimen
write(9,'(i23,3a)') id(i),':[',trim(adjustl(fname(id(i)))),']'
end do

2009 format(a20,i3.3,a2,*(e20.10))
2010 format(a20,a3,a2,*(e20.10))
2011 format(a10,2a20,*(a19,i1.1))
2012 format(i10,*(e20.10))

do i=1,ntask
  write(9,2009) ' coefficients_',i,': ', betamin(:idimen,i)
  write(9,'(a20,i3.3,a2,e20.10)') '  Intercept_',i,': ', interceptmin(i)
  write(9,'(a20,i3.3,a2,2e20.10)') ' RMSE,MaxAE_',i,': ', LSrmse(i),LSmaxae(i)
!  write(9,'(a20,i3.3,a2,2e20.10)') ' CVrmse,maxAE_',i,': ', CVrmse(i),CVmaxae(i)
  write(line_name,'(a,i3.3,a,i3.3,a)') 'desc_',idimen,'d_p',i,'.dat'
  open(funit,file='desc_dat/'//trim(adjustl(line_name)),status='replace')
  write(funit,2011) 'Index','y_measurement','y_fitting',('descriptor_',j,j=1,idimen)
  do j=1,nsample(i)
     yfit=interceptmin(i)+sum(x(j,[id(:idimen)],i)*betamin(:idimen,i))
     write(funit,2012) j,y(j,i),yfit,x(j,[id(:idimen)],i)
  end do
  close(funit)
end do
write(9,'(a)')'================================================================================'

end subroutine


!subroutine foldCV(x,y,random,CVrmse,CVmaxae)
!! output CVrmse, CVmaxae
!integer ns,fold,random(:),mm1,mm2,mm3,mm4,i,j,k,kk,l
!real*8 x(:,:),y(:),beta(ubound(x,2)),intercept,rmse,CVse(CV_fold),CVrmse,CVmaxae,pred(ubound(y,1))
!
!ns=ubound(y,1)
!CVmaxae=0
!CVrmse=0
!fold=CV_fold
!if(fold>ns) fold=ns
!
!k=int(ns/fold)
!kk=mod(ns,fold)
!do l=1,fold
!   mm1=1  ! sample start
!   mm2=ns      ! sample end
!   mm3=(l-1)*k+min((l-1),kk)+1 ! test start
!   mm4=mm3+k-1+int(min(l,kk)/l)  ! test end
!   if(mm1==mm3) then
!      call orth_de(x([random(mm4+1:mm2)],:),y([random(mm4+1:mm2)]),intercept,beta(:),rmse)
!   else if(mm4==mm2) then
!      call orth_de(x([random(mm1:mm3-1)],:),y([random(mm1:mm3-1)]),intercept,beta(:),rmse)
!   else
!      call orth_de(x([random(mm1:mm3-1),random(mm4+1:mm2)],:),&
!                   y([random(mm1:mm3-1),random(mm4+1:mm2)]),intercept,beta(:),rmse)
!   end if
!   pred(mm3:mm4)=(intercept+matmul(x([random(mm3:mm4)],:),beta(:)))
!end do
!CVmaxae=maxval(abs(y([random])-pred))
!CVrmse=sqrt(sum((y([random])-pred)**2)/ns)  ! RMSE
!
!end subroutine

!subroutine rand_order(random)
!! prepare random number for CV
!integer random(:),i,j,k,ns
!real tmp
!ns=ubound(random,1)
!random=0
!   j=0
!   do while(j<ns)
!      call random_number(tmp)
!      k=ceiling(tmp*ns)
!      if(all(k/=random)) then
!      j=j+1
!      random(j)=k
!      end if
!   end do
!end subroutine


! descriptor for classification
subroutine model2(x,fname,nactive,activeset)
integer nactive,activeset(:),i,j,k,l,loc(1),ii(dim_DI),itask,mm1,mm2,mm3,mm4,ns,&
idimen,select_model(max(nm_output,1),dim_DI),mID(max(nm_output,1),dim_DI),overlap_n,overlap_n_tmp,&
select_overlap_n(max(nm_output,1)),nh,ntri,nconvexpair
integer*8 totalm,bigm,nall,nrecord,nlower,nupper
real*8  x(:,:,:),mscore(max(nm_output,1),2),overlap_area,overlap_area_tmp,select_overlap_area(max(nm_output,1)),&
hull(maxval(nsample),2),area(maxval(ngroup(:,1000))),mindist,xtmp1(ubound(x,1),3),xtmp2(ubound(x,1),3)
character fname(:)*200,line_name*100
integer*8 njob(mpisize)
real*8 mpicollect(mpisize,2)
logical isoverlap
real progress
integer,allocatable:: triangles(:,:)

if(nm_output<1) nm_output=1

if(mpirank==0) then
write(9,'(a)') 'L0 starts ...'
end if

do idimen=1,dim_DI

  progress=0.2

  if(idimen<dim_DI) cycle ! .and. trim(adjustl(calc))=='FCDI') cycle
  if(idimen>3) exit  ! up to 3D

   ! job assignment for each CPU core
   nall=1
   do mpii=1,idimen
      nall=nall*(nactive-mpii+1)/mpii
   end do
   if(nactive==idimen) nall=1
   njob=nall/mpisize

   mpij=mod(nall,int8(mpisize))
   do mpii=1,mpisize-1
     if(mpii<=mpij) njob(mpii+1)=njob(mpii+1)+1   
   end do

   ! initialization   
   select_overlap_n=sum(nsample)*sum(ngroup(:,1000))  ! set to a large value
   totalm=0

! get the best nm_output models on each CPU core
   nrecord=0
   do k=1,nactive
      ii(1)=k

      do j=2,idimen
        ii(j)=ii(j-1)+1   ! starting number
      end do      

      nlower=sum(njob(:mpirank))+1
      nupper=sum(njob(:mpirank+1))
      123 continue 
      nrecord=nrecord+1

      if( nrecord< nlower) goto 124
      if( nrecord> nupper) exit

      if(float(nrecord-nlower+1)/float(njob(mpirank+1))>=progress) then
        write(*,'(a,i4,a,i4,a,f6.1,a)') 'dimension=',idimen,'    mpirank= ',mpirank,'    progress =',progress*100,'%'
        progress=progress+0.2
      end if

      ! initialization
      overlap_n=0
      overlap_area=0.d0
      mindist=-1d10
      isoverlap=.false.
      nconvexpair=0

      !------ get the score for this model ----------
      do itask=1,ntask
        ! area
           if(idimen==1) then
             do i=1,ngroup(itask,1000) ! number of groups in the task $itask
              if(isconvex(itask,i)==0) cycle
              mm1=sum(ngroup(itask,:i-1))+1 
              mm2=sum(ngroup(itask,:i))
              area(i)=maxval(x(mm1:mm2,[activeset(ii(:idimen))],itask))-minval(x(mm1:mm2,[activeset(ii(:idimen))],itask))
             end do
           else if(idimen==2) then
             do i=1,ngroup(itask,1000)
              if(isconvex(itask,i)==0) cycle
              mm1=sum(ngroup(itask,:i-1))+1 
              mm2=sum(ngroup(itask,:i))
              area(i)=convex2d_area(x(mm1:mm2,[activeset(ii(:idimen))],itask))
             end do
           else if(idimen==3) then
             area(:ngroup(itask,1000))=1.d0  ! not yet implemented for 3D volumes
           end if

        !  model scores
           do i=1,ngroup(itask,1000)-1
             mm1=sum(ngroup(itask,:i-1))+1
             mm2=sum(ngroup(itask,:i))
             do j=i+1,ngroup(itask,1000)
               mm3=sum(ngroup(itask,:j-1))+1
               mm4=sum(ngroup(itask,:j))

               IF(isconvex(itask,i)==1 .and. isconvex(itask,j)==1) then
                 nconvexpair=nconvexpair+1
                 if(idimen==1) then
                     xtmp1(mm1:mm2,1)=x(mm1:mm2,activeset(ii(idimen)),itask)
                     xtmp2(mm3:mm4,1)=x(mm3:mm4,activeset(ii(idimen)),itask)
                     call convex1d_overlap(xtmp1(mm1:mm2,1),xtmp2(mm3:mm4,1),width,overlap_n_tmp,overlap_area_tmp)
                 else if(idimen==2) then
                     xtmp1(mm1:mm2,:2)=x(mm1:mm2,activeset(ii(:2)),itask)
                     xtmp2(mm3:mm4,:2)=x(mm3:mm4,activeset(ii(:2)),itask)
                     call convex2d_overlap(xtmp1(mm1:mm2,:2),xtmp2(mm3:mm4,:2),width,overlap_n_tmp,overlap_area_tmp)
                 else if(idimen==3) then
                     xtmp1(mm1:mm2,:3)=x(mm1:mm2,activeset(ii(:3)),itask)
                     xtmp2(mm3:mm4,:3)=x(mm3:mm4,activeset(ii(:3)),itask)
                     call convex3d_overlap(xtmp1(mm1:mm2,:3),xtmp2(mm3:mm4,:3),width,overlap_n_tmp)
                     overlap_area_tmp=0.d0  ! Calculating overlap_area is not implemented
                 end if
                 overlap_n=overlap_n+overlap_n_tmp
                 if(overlap_area_tmp>=0) isoverlap=.true.
 
                 if(.not. isoverlap) then  ! if separated
                     if(mindist<overlap_area_tmp) then
                         mindist=overlap_area_tmp ! renew the worst separation
                         overlap_area=mindist  ! smaller, better
                     end if
                 else 
                     if(overlap_area_tmp>=0.d0 .and. min(area(i),area(j))==0.d0) then ! if overlapped with a 0D feature
                         overlap_area=max(0.d0,overlap_area)+1.d0   ! totally overlapped
                    else if (overlap_area_tmp>=0.d0 .and. min(area(i),area(j))>0.d0) then ! if overlapped without 0D feature
                         overlap_area=max(0.d0,overlap_area)+overlap_area_tmp/(min(area(i),area(j)))  ! calculate total overlap
                    end if
                 end if

              ELSE IF(isconvex(itask,i)==1 .and. isconvex(itask,j)==0) then
                 if(idimen==1) then
                     xtmp1(mm1:mm2,1)=x(mm1:mm2,activeset(ii(idimen)),itask)
                     xtmp2(mm3:mm4,1)=x(mm3:mm4,activeset(ii(idimen)),itask)
                     overlap_n=overlap_n+convex1d_in(xtmp1(mm1:mm2,1),xtmp2(mm3:mm4,1),width)
                 else if(idimen==2) then
                     xtmp1(mm1:mm2,:2)=x(mm1:mm2,activeset(ii(:2)),itask)
                     xtmp2(mm3:mm4,:2)=x(mm3:mm4,activeset(ii(:2)),itask)
                     overlap_n=overlap_n+convex2d_in(xtmp1(mm1:mm2,:2),xtmp2(mm3:mm4,:2),width)
                 else if(idimen==3) then
                     xtmp1(mm1:mm2,:3)=x(mm1:mm2,activeset(ii(:3)),itask)
                     xtmp2(mm3:mm4,:3)=x(mm3:mm4,activeset(ii(:3)),itask)
                     call convex3d_hull(xtmp1(mm1:mm2,:3),ntri,triangles)
                     overlap_n=overlap_n+convex3d_in(xtmp1(mm1:mm2,:3),xtmp2(mm3:mm4,:3),width,ntri,triangles)
                     deallocate(triangles)
                 end if
              ELSE IF(isconvex(itask,i)==0 .and. isconvex(itask,j)==1) then
                 if(idimen==1) then
                     xtmp1(mm1:mm2,1)=x(mm1:mm2,activeset(ii(idimen)),itask)
                     xtmp2(mm3:mm4,1)=x(mm3:mm4,activeset(ii(idimen)),itask)
                     overlap_n=overlap_n+convex1d_in(xtmp2(mm3:mm4,1),xtmp1(mm1:mm2,1),width)
                 else if(idimen==2) then
                     xtmp1(mm1:mm2,:2)=x(mm1:mm2,activeset(ii(:2)),itask)
                     xtmp2(mm3:mm4,:2)=x(mm3:mm4,activeset(ii(:2)),itask)
                     overlap_n=overlap_n+convex2d_in(xtmp2(mm3:mm4,:2),xtmp1(mm1:mm2,:2),width)
                 else if(idimen==3) then
                     xtmp1(mm1:mm2,:3)=x(mm1:mm2,activeset(ii(:3)),itask)
                     xtmp2(mm3:mm4,:3)=x(mm3:mm4,activeset(ii(:3)),itask)
                     call convex3d_hull(xtmp2(mm3:mm4,:3),ntri,triangles)
                     overlap_n=overlap_n+convex3d_in(xtmp2(mm3:mm4,:3),xtmp1(mm1:mm2,:3),width,ntri,triangles)
                     deallocate(triangles)
                 end if
              END IF

             end do ! j
           end do ! i
         end do ! itask
         
         if(isoverlap)  overlap_area=overlap_area/float(nconvexpair) ! smaller, better
         !----------------------------------

      ! store good models 
      if (any(overlap_n<select_overlap_n)) then
         totalm=totalm+1
         loc=maxloc(select_overlap_n)
         select_overlap_n(loc(1))=overlap_n
         select_overlap_area(loc(1))=overlap_area
         select_model(loc(1),:idimen)=activeset(ii(:idimen))
      else if (overlap_n==maxval(select_overlap_n) .and. any(overlap_area<select_overlap_area) )  then
         totalm=totalm+1
         loc=maxloc(select_overlap_area)
         select_overlap_n(loc(1))=overlap_n
         select_overlap_area(loc(1))=overlap_area
         select_model(loc(1),:idimen)=activeset(ii(:idimen))         
      end if

      ! update models(123,124,125,134,135,145,234,...)
      124 continue
      if(idimen==1) cycle
      ii(idimen)=ii(idimen)+1  ! add 1 for the highest dimension

      do j=idimen,3,-1
        if(ii(j)> (nactive-(idimen-j)) ) ii(j-1)=ii(j-1)+1 
      end do
      do j=3,idimen
        if(ii(j)> (nactive-idimen+j) ) ii(j)=ii(j-1)+1
      end do
      if(ii(2)>(nactive-(idimen-2)))  cycle
      goto 123
   end do

! collecting the best models from all CPU cores
   if(mpirank>0) then
     call mpi_send(totalm,1,mpi_integer8,0,1,mpi_comm_world,status,mpierr)
   else
     do i=1,mpisize-1
       call mpi_recv(bigm,1,mpi_integer8,i,1,mpi_comm_world,status,mpierr)
       totalm=totalm+bigm
     end do
   end if
   call mpi_bcast(totalm,1,mpi_integer8,0,mpi_comm_world,mpierr)

   do j=1,min(int8(nm_output),totalm)
      loc=minloc(select_overlap_n)
      do k=1,min(int8(nm_output),totalm)
        if(select_overlap_n(k)==select_overlap_n(loc(1)) .and. &
           select_overlap_area(k)<select_overlap_area(loc(1))) loc(1)=k
      end do
      k=loc(1)
      mscore(j,:)=(/dble(select_overlap_n(k)),select_overlap_area(k)/)

      if(mpirank>0) then
        call mpi_send(mscore(j,:),2,mpi_double_precision,0,1,mpi_comm_world,status,mpierr)
      else
        mpicollect(1,:)=mscore(j,:)
        do i=1,mpisize-1
          call mpi_recv(mpicollect(i+1,:),2,mpi_double_precision,i,1,mpi_comm_world,status,mpierr)
        end do
        loc=minloc(mpicollect(:,1))
        do l=1,mpisize
          if(mpicollect(l,1)==mpicollect(loc(1),1) .and. &
             mpicollect(l,2)<mpicollect(loc(1),2) ) loc(1)=l
        end do
        l=loc(1)
      end if
      call mpi_bcast(l,1,mpi_integer,0,mpi_comm_world,mpierr)

      if(mpirank==l-1) then
        mID(j,:idimen)=select_model(k,:idimen)
        select_overlap_n(k)=sum(nsample)*sum(ngroup(:,1000))   ! set to large to avoid to be selected again
      end if
      call mpi_bcast(mID(j,:idimen),idimen,mpi_integer,l-1,mpi_comm_world,mpierr)
      call mpi_bcast(mscore(j,:),2,mpi_double_precision,l-1,mpi_comm_world,mpierr)
   end do

   if(mpirank==0) then
      call writeout2(x,idimen,mID(1,:idimen),fname,mscore)

2013  format(i10,i20,f20.5,a,*(i8))
2014  format(i10,i20,a,*(i8))
      if(nm_output>1) then
        write(line_name,'(a,i4.4,a,i3.3,a)') 'top',min(int8(nm_output),totalm),'_',idimen,'d'
        open(funit,file='models/'//trim(adjustl(line_name)),status='replace')
        if(idimen<=2) then
            write(funit,'(a10,3a20)') 'Rank','#data_overlap','size_overlap','Feature_ID'
        else 
            write(funit,'(a10,2a20)') 'Rank','#data_overlap','Feature_ID'
        end if
        do i=1,min(int8(nm_output),totalm)
           if(idimen<=2) then
               write(funit,2013,advance='no') i,nint(mscore(i,1)),mscore(i,2),'   (',mID(i,:idimen)
           else
               write(funit,2014,advance='no') i,nint(mscore(i,1)),'   (',mID(i,:idimen)
           end if
           write(funit,'(a)') ')'
        end do
        close(funit)
      end if

      if(idimen>=2) then
        if(idimen==2) then
           open(funit,file='convex2d_hull',status='replace')
           write(funit,'(a)') 'The coordinates (x,y) of 2D-vertices arranged in clockwise direction'
        end if
        if(idimen==3) then
           open(funit,file='convex3d_hull',status='replace')
           write(funit,'(a)') 'Facet-triangles with each indicated by three indexes of the data of this class'
           write(funit,'(a)') 'E.g.: ploting a 3D convex hull by using the MATLAB function: trisurf(Tri,X,Y,Z)'
        end if

         do itask=1,ntask
         write(funit,'(a,i5)') 'Task :',itask
         do i=1,ngroup(itask,1000)
           mm1=sum(ngroup(itask,:i-1))+1
           mm2=sum(ngroup(itask,:i))
           if(isconvex(itask,i)==0) cycle
           write(funit,'(a,i5,g20.10)') 'Hull',i
           if(idimen==2) then
              call convex2d_hull(x(mm1:mm2,[mID(1,:idimen)],itask),j,hull)
              do k=1,j
                write(funit,'(2e20.10)') hull(k,:)
              end do
           elseif(idimen==3) then
              call convex3d_hull(x(mm1:mm2,[mID(1,:idimen)],itask),j,triangles)
              do k=1,j
                write(funit,'(3i5)') triangles(k,:)
              end do
              deallocate(triangles) ! allocated in the convex3d_hull subroutine
           end if
         end do
         end do
         close(funit)
      end if
   end if
end do

call mpi_barrier(mpi_comm_world,mpierr)
end subroutine


subroutine writeout2(x,idimen,id,fname,mscore)
integer idimen,i,j,id(:),k,l,itask,mm1,mm2,mm3,mm4,ndata_ol,ntri
integer,allocatable:: triangles(:,:)
real*8 mscore(:,:),tmp,tmp2,x(:,:,:)
character fname(:)*200,line_name*100
logical inside,convexpair

2015 format(2a20,*(a19,i1.1))
2016 format(2i20,*(e20.10))

ndata_ol=0
do itask=1,ntask
  write(line_name,'(a,i3.3,a,i3.3,a)') 'desc_',idimen,'d_p',itask,'.dat'
  open(funit,file='desc_dat/'//trim(adjustl(line_name)),status='replace')
  write(funit,2015) 'Index','classified?',('descriptor_',j,j=1,idimen)
  do i=1,ngroup(itask,1000)  ! the groups in this task $itask
  do j=sum(ngroup(itask,:i-1))+1,sum(ngroup(itask,:i))  ! samples in this group
     inside=.false.
     do k=1,ngroup(itask,1000)  ! check if sample j of group i is in the domain of group k
       if(i==k) cycle
       if(isconvex(itask,k)==0) cycle ! group k is not convex domain
       mm1=sum(ngroup(itask,:k-1))+1
       mm2=sum(ngroup(itask,:k))
       if(idimen==1) then
            if(convex1d_in(x(mm1:mm2,id(idimen),itask),x(j:j,id(idimen),itask),width)==1) then
              inside=.true.
              exit
            end if
       elseif(idimen==2) then
           if(convex2d_in(x(mm1:mm2,[id(:idimen)],itask),x(j:j,[id(:idimen)],itask),width)==1) then
             inside=.true.
             exit
           end if
       elseif(idimen==3) then
           call convex3d_hull(x(mm1:mm2,[id(:idimen)],itask),ntri,triangles)
           if(convex3d_in(x(mm1:mm2,[id(:idimen)],itask),x(j:j,[id(:idimen)],itask),width,ntri,triangles)==1) then
             inside=.true.
             deallocate(triangles)
             exit
           end if
           deallocate(triangles)
      end if
    end do

    if(inside) then
        write(funit,2016) j,0,x(j,[id(:idimen)],itask)  ! unclassified
        ndata_ol=ndata_ol+1
    else
        write(funit,2016) j,1,x(j,[id(:idimen)],itask) ! classified
    end if
  end do
  end do
  close(funit)
end do

if(idimen==desc_dim) then ! .and. trim(adjustl(calc))=='FCDI') then
  write(9,'(/a)')  'Final model/descriptor to report'
else if(idimen<desc_dim) then ! .and. trim(adjustl(calc))=='FCDI') then
  write(9,'(/a)')  'Model/descriptor for generating residual:'
!else if(trim(adjustl(calc))=='DI') then
!  write(9,'(/a)')  'Model/descriptor to report' 
end if
write(9,'(a)')'================================================================================'
write(9,'(i3,a)') idimen,'D descriptor (model): '
write(9,'(a,i10)') 'Number of data in all overlap regions:',int(mscore(1,1))
convexpair=.false.
do itask=1,ntask
  do i=1,ngroup(itask,1000)
    do j=i+1,ngroup(itask,1000)
       if(isconvex(itask,i)==1 .and. isconvex(itask,j)==1) convexpair=.true.
    end do
  end do
end do
if(idimen<=2 .and. convexpair) then
  write(9,'(a,f15.5)') 'Size of the overlap:',mscore(1,2)
  write(9,'(a)') 'Note: >0, overlap-size; <0, distance (absolute value) between separated domains'
end if
write(9,'(a,i10)') 'Actual number (without double counting) of data in all overlap regions: ', ndata_ol
write(9,'(a)')  '@@@descriptor: '
do i=1,idimen
write(9,'(i23,3a)') id(i),':[',trim(adjustl(fname(id(i)))),']'
end do
write(9,'(a)')'================================================================================'

end subroutine

end module

