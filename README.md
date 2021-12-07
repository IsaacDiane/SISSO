cd src

mpifort -O2 var_global.f90 libsisso.f90 DI.f90 FC.f90 SISSO.f90 -o SISSO

cd mrmr_c_src

make -f mrmr.makefile

cp mrmr ../mrmr

then put your SISSO,mrmr,train.set,SISSO.in into one file.

./SISSO



