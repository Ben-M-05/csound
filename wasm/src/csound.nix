{ pkgs ? import <nixpkgs> { }, static ? false }:

let
  lib = pkgs.lib;
  wasi-sdk-dyn = pkgs.callPackage ./wasi-sdk.nix { };
  wasi-sdk-static = pkgs.callPackage ./wasi-sdk-static.nix { };
  wasi-sdk = if static then wasi-sdk-static else wasi-sdk-dyn;
  static-link = ''
    echo "Create libcsound.wasm standalone"
    ${wasi-sdk}/bin/wasm-ld --lto-O3 \
      --entry=_start \
      ${
         pkgs.lib.concatMapStrings (x: " --export=" + x + " ")
         (with builtins; fromJSON (readFile ./exports.json))
       } \
      -L${wasi-sdk}/share/wasi-sysroot/lib/wasm32-wasi \
      -L${libsndfile}/lib \
      -lc  -lc++ -lc++abi \
      -lsndfile -lwasi-emulated-signal -lwasi-emulated-mman \
      ${wasi-sdk}/share/wasi-sysroot/lib/wasm32-wasi/crt1.o \
       *.o -o libcsound.wasm
  '';
  dyn-link = ''
    echo "Create libcsound.wasm pie"
    ${wasi-sdk}/bin/wasm-ld --lto-O0 \
      --experimental-pic -pie --entry=_start \
      --import-table --import-memory \
      ${
         pkgs.lib.concatMapStrings (x: " --export=" + x + " ")
         (with builtins; fromJSON (readFile ./exports.json))
       } \
      -L${wasi-sdk}/share/wasi-sysroot/lib/wasm32-unknown-emscripten \
      -L${libsndfile}/lib \
      -lc  -lc++ -lc++abi \
      -lsndfile -lwasi-emulated-signal -lwasi-emulated-mman \
      ${wasi-sdk}/share/wasi-sysroot/lib/wasm32-unknown-emscripten/crt1.o \
       *.o -o libcsound.wasm

  '';
  exports = with builtins; (fromJSON (readFile ./exports.json));
  patchClock = pkgs.writeTextFile {
    name = "patchClock";
    executable = true;
    destination = "/bin/patchClock";
    text = ''
      #!${pkgs.nodejs}/bin/node
      const myArgs = process.argv.slice(2);
      const myFile = myArgs[0];
      const fs = require('fs')
      fs.readFile(myFile, 'utf8', function (err,data) {
        if (err) { return console.log(err); }
        const regex = "\\/\\* find out CPU frequency based on.*" +
                      "initialise a timer structure \\*\\/";
        const replace = `static int getTimeResolution(void) { return 0; }
        int gettimeofday (struct timeval *__restrict, void *__restrict);
        static inline int_least64_t get_real_time(void) {
          struct timeval tv;
          gettimeofday(&tv, NULL);
          return ((int_least64_t) tv.tv_usec
            + (int_least64_t) ((uint32_t) tv.tv_sec * (uint64_t) 1000000));}
        clock_t clock (void);
        static inline int_least64_t get_CPU_time(void) {
          return ((int_least64_t) ((uint32_t) clock()));
        }`;
        const result = data.replace(new RegExp(regex, 'is'), replace);
        fs.writeFile(myFile, result, 'utf8', function (err) {
          if (err) return console.log(err);
        });
      });
    '';
  };

  libsndfile = pkgs.callPackage ./libsndfile.nix { inherit static; };

  csoundModLoadPatch = pkgs.writeTextFile {
    name = "csoundModLoadPatch";
    text = ''
      #ifndef __MODLOAD__H
      #define __MODLOAD__H
      #include <plugin.h>
      namespace csnd {
        void on_load(Csound *);
      }
      #endif
    '';
  };

  csoundSrc = with builtins; pkgs.fetchFromGitHub (fromJSON (readFile ./version.json));

  preprocFlags = ''
    -DGIT_HASH_VALUE=${csoundSrc.rev} \
    -DUSE_DOUBLE=1 \
    -DLINUX=0 \
    -DO_NDELAY=O_NONBLOCK \
    -DHAVE_STRLCAT=1 \
    -Wno-unknown-attributes \
    -Wno-shift-op-parentheses \
    -Wno-bitwise-op-parentheses \
    -Wno-many-braces-around-scalar-init \
    -Wno-macro-redefined \
  '';

in pkgs.stdenvNoCC.mkDerivation rec {

  name = "csound-wasm";

  src = csoundSrc;

  buildInputs = [ pkgs.flex pkgs.bison ];

  dontStrip = true;
  AR = "${wasi-sdk}/bin/ar";
  CC = "${wasi-sdk}/bin/clang";
  CPP = "${wasi-sdk}/bin/clang-cpp";
  CXX = "${wasi-sdk}/bin/clang++";
  LD = "${wasi-sdk}/bin/wasm-ld";
  NM = "${wasi-sdk}/bin/nm";
  OBJCOPY = "${wasi-sdk}/bin/objcopy";
  RANLIB = "${wasi-sdk}/bin/ranlib";

  postPatch = ''
    # Experimental setjmp patching
    find ./ -type f -exec sed -i -e 's/#include <setjmp.h>//g' {} \;
    find ./ -type f -exec sed -i -e 's/csound->LongJmp(csound, retval);/return retval;/g' {} \;
    find ./ -type f -exec sed -i -e 's/csound->LongJmp(.*)//g' {} \;
    find ./ -type f -exec sed -i -e 's/longjmp(.*)//g' {} \;
    find ./ -type f -exec sed -i -e 's/jmp_buf/int/g' {} \;
    find ./ -type f -exec sed -i -e 's/setjmp(csound->exitjmp)/0/g' {} \;

    # find ./ -type f -exec sed -i -e 's/csound->Calloc/mcalloc/g' {} \;

    find ./ -type f -exec sed -i -e 's/HAVE_PTHREAD/FFS_NO_PTHREADS/g' {} \;
    find ./ -type f -exec sed -i -e 's/#ifdef LINUX/#ifdef _NOT_LINUX_/g' {} \;
    find ./ -type f -exec sed -i -e 's/if(LINUX)/if(_NOT_LINUX_)/g' {} \;
    find ./ -type f -exec sed -i -e 's/if (LINUX)/if(_NOT_LINUX_)/g' {} \;
    find ./ -type f -exec sed -i -e 's/defined(LINUX)/defined(_NOT_LINUX_)/g' {} \;

    # don't export dynamic modules
    find ./ -type f -exec sed -i -e 's/PUBLIC.*int.*csoundModuleCreate /static int csoundModuleCreate/g' {} \;
    find ./ -type f -exec sed -i -e 's/PUBLIC.*int32_t.*csoundModuleCreate /static int32_t csoundModuleCreate/g' {} \;
    find ./ -type f -exec sed -i -e 's/PUBLIC.*int.*csound_opcode_init/static int csound_opcode_init/g' {} \;
    find ./ -type f -exec sed -i -e 's/PUBLIC.*int32_t.*csound_opcode_init/static int32_t csound_opcode_init/g' {} \;
    find ./ -type f -exec sed -i -e 's/PUBLIC.*int.*csoundModuleInfo/static int csoundModuleInfo/g' {} \;
    find ./ -type f -exec sed -i -e 's/PUBLIC.*int32_t.*csoundModuleInfo/static int32_t csoundModuleInfo/g' {} \;
    find ./ -type f -exec sed -i -e 's/PUBLIC.*NGFENS.*\*csound_fgen_init/static NGFENS *csound_fgen_init/g' {} \;

    sed -i -e 's/csoundUDPConsole.*//g' Top/argdecode.c

    cat ${csoundModLoadPatch} > include/modload.h

    # Todo: add this to csound proper
    substituteInPlace H/csmodule.h \
      --replace 'int csoundLoadModules(CSOUND *csound);' \
                'int csoundLoadModules(CSOUND *csound)
                 __attribute__((__import_module__("env"),
                                __import_name__("csoundLoadModules")));'

    # Patch 64bit integer clock
    ${patchClock}/bin/patchClock Top/csound.c

    touch include/float-version.h
    substituteInPlace Top/csmodule.c \
      --replace '#include <dlfcn.h>' ""
    substituteInPlace Engine/csound_orc.y \
      --replace 'csound_orcnerrs' "0"
    substituteInPlace include/sysdep.h \
      --replace '#if defined(HAVE_GCC3) && !defined(SWIG)' \
    '#if defined(HAVE_GCC3) && !defined(WASM_BUILD)'

    # don't open .csound6rc
    substituteInPlace Top/main.c \
      --replace 'checkOptions(csound);' ""

    # follow same preproc defs as emscripten
    # when it come to filesystem calls
    substituteInPlace OOps/diskin2.c \
      --replace '__EMSCRIPTEN__' 'WASM_BUILD'

    substituteInPlace Engine/csound_orc_compile.c \
      --replace '#ifdef EMSCRIPTEN' '#if 1' \
      --replace 'void sanitize(CSOUND *csound) {}' \
                'void sanitize(CSOUND *csound);'

    substituteInPlace Top/one_file.c \
      --replace '#include "corfile.h"' \
            '#include "corfile.h"
             #include <sys/types.h>
             #include <sys/stat.h>
             #include <string.h>
             #include <stdlib.h>
             #include <unistd.h>
             #include <fcntl.h>
             #include <errno.h>' \
             --replace 'umask(0077);' "" \
             --replace 'mkstemp(lbuf)' \
             'open(lbuf, 02)' \
             --replace 'system(sys)' '-1'

    substituteInPlace Engine/linevent.c \
      --replace '#include <ctype.h>' \
         '#include <ctype.h>
          #include <string.h>
          #include <stdlib.h>
          #include <unistd.h>
          #include <fcntl.h>
          #include <errno.h>'

    substituteInPlace Opcodes/urandom.c \
      --replace '__HAIKU__' \
        'WASM_BUILD
         #include <unistd.h>'

    substituteInPlace InOut/libmpadec/mp3dec.c \
      --replace '#include "csoundCore.h"' \
                '#include "csoundCore.h"
                 #include <stdlib.h>
                 #include <stdio.h>
                 #include <sys/types.h>
                 #include <unistd.h>
                 '

    substituteInPlace Opcodes/mp3in.c \
      --replace '#include "mp3dec.h"' \
        '#include "mp3dec.h"
         #include <unistd.h>
         #include <fcntl.h>'

    substituteInPlace Top/csound.c \
      --replace 'strcpy(s, "alsa");' 'strcpy(s, "wasi");' \
      --replace 'strcpy(s, "hostbased");' "" \
      --replace 'signal(sigs[i], signal_handler);' "" \
      --replace 'static void psignal' 'static void psignal_' \
      --replace 'HAVE_RDTSC' '__NOT_HERE___' \
      --replace '#if !defined(WIN32)' '#if 0' \
      --replace 'static double timeResolutionSeconds = -1.0;' \
                'static double timeResolutionSeconds = 0.000001;'

    substituteInPlace Engine/envvar.c \
      --replace 'return name;' \
                'char* fsPrefix = csound->Malloc(
                   csound, (size_t) strlen(name) + 9);
                 strcpy(fsPrefix, (name[0] == DIRSEP) ? "/sandbox" : "/sandbox/");
                 strcat(fsPrefix, name);
                 return fsPrefix;' \
      --replace '#include <math.h>' \
                '#include <math.h>
                 #include <string.h>
                 #include <stdlib.h>
                 #include <unistd.h>
                 #include <fcntl.h>
                 #include <errno.h>
                 #define getcwd(x,y) "/"
                 static void strcat_beg(char *src, char *dst)
                 {
                 size_t dst_len = strlen(dst) + 1, src_len = strlen(src);
                 memmove(dst + src_len, dst, dst_len);
                 memcpy(dst, src, src_len);
                 }
                 '

    # since we recommend n^2 number,
    # let's make sure that it's default too
    substituteInPlace include/csoundCore.h \
      --replace '#define DFLT_KSMPS 10' \
                '#define DFLT_KSMPS 16' \
      --replace '#define DFLT_KR    FL(4410.0)' \
                '#define DFLT_KR    FL(2756.25)'

    substituteInPlace Top/main.c \
      --replace 'csoundUDPServerStart(csound,csound->oparms->daemon);' "" \
      --replace 'static void put_sorted_score' \
                'extern void put_sorted_score'
    substituteInPlace Engine/musmon.c \
      --replace 'csoundUDPServerClose(csound);' ""

    substituteInPlace Engine/new_orc_parser.c \
      --replace 'csound_orcdebug = O->odebug;' ""

    substituteInPlace Top/init_static_modules.c \
      --replace 'csoundMessage(csound, "init_static_modules...\n");' ""

    # expose scansyn_init_ via extern
    # also hardcode away graph console logs
    # as they seem to freeze the browser environment
    substituteInPlace Opcodes/scansyn.c \
      --replace 'static int32_t scansyn_init_' \
                'extern int32_t scansyn_init_' \
      --replace '*p->i_disp' '0'
    substituteInPlace Opcodes/scansyn.h \
      --replace 'extern int32_t' \
                'extern int32_t scansyn_init_(CSOUND *);
                 extern int32_t'

    # link emugens statically
    substituteInPlace Opcodes/emugens/emugens.c \
      --replace 'LINKAGE' \
       'int32_t emugens_init_(CSOUND *csound) {
           return csound->AppendOpcodes(csound,
             &(localops[0]), (int32_t) (sizeof(localops) / sizeof(OENTRY))); }'
    echo 'extern int32_t emugens_init_(CSOUND *);' >> \
      Opcodes/emugens/emugens_common.h

    # opcode-lib: liveconv
    substituteInPlace Opcodes/liveconv.c \
      --replace 'LINKAGE' \
       'int32_t liveconv_init_(CSOUND *csound) {
           return csound->AppendOpcodes(csound,
             &(localops[0]), (int32_t) (sizeof(localops) / sizeof(OENTRY))); }'

    # date and fs
    sed -i '1s/^/#include <unistd.h>\n/' Opcodes/date.c
    sed -i -e 's/LINUX/1/g' Opcodes/date.c
    substituteInPlace Opcodes/date.c \
      --replace 'LINKAGE_BUILTIN(date_localops)' \
       'int32_t dateops_init_(CSOUND *csound) {
           return csound->AppendOpcodes(csound,
             &(date_localops[0]), (int32_t) (sizeof(date_localops) / sizeof(OENTRY))); }'

    echo 'extern "C" {
     extern int pvsops_init_(CSOUND *csound) {
       csnd::on_load((csnd::Csound *)csound);
       return 0;
     }
    }' >>  Opcodes/pvsops.cpp

    rm CMakeLists.txt
  '';

  configurePhase = ''
    ${pkgs.bison}/bin/bison -pcsound_orc -d --report=itemset ./Engine/csound_orc.y \
      -o ./Engine/csound_orcparse.c
    # ${pkgs.bison}/bin/bison -pcsound_sco -d --report=itemset ./Engine/csound_sco.y \
    #   --defines=./H/csound_scoparse.h \
    #   -o ./Engine/csound_scoparse.c

    ${pkgs.flex}/bin/flex -B ./Engine/csound_orc.lex > ./Engine/csound_orclex.c
    ${pkgs.flex}/bin/flex -B ./Engine/csound_pre.lex > ./Engine/csound_prelex.c
    ${pkgs.flex}/bin/flex -B ./Engine/csound_prs.lex > ./Engine/csound_prslex.c
    # ${pkgs.flex}/bin/flex -B ./Engine/csound_sco.lex > ./Engine/csound_scolex.c
  '';

  buildPhase = ''
    cp ${ ./csdl_with_proposal.h } include/csdl.h
    cp ${ ./csmodule_with_proposal.c } Top/csmodule.c
    cp ${ ./modload_with_proposal.h } include/modload.h
    mkdir -p build && cd build
    cp ${./csound_wasm.c} ./csound_wasm.c
    cp ${./unsupported_opcodes.c} ./unsupported_opcodes.c

    # Why the wasm32-unknown-emscripten triplet:
    # https://bugs.llvm.org/show_bug.cgi?id=42714
    echo "Compile libcsound.wasm"
    ${wasi-sdk}/bin/clang \
      ${lib.optionalString (static == false) "--target=wasm32-unknown-emscripten" } \
      --sysroot=${wasi-sdk}/share/wasi-sysroot \
      -fno-force-enable-int128 \
      ${lib.optionalString (static == false) "-fPIC" } -fno-exceptions -fno-rtti -O3 \
      -I../H -I../Engine -I../include -I../ \
      -I../InOut/libmpadec \
      -I${libsndfile}/include \
      -I${wasi-sdk}/share/wasi-sysroot/include/c++/v1 \
      -DINIT_STATIC_MODULES=1 \
      -U__MACH__ \
      -UMAC \
      -UMACOSX \
      -D__wasi__=1 \
      -D__wasm32__=1 \
      -D_WASI_EMULATED_SIGNAL \
      -D_WASI_EMULATED_MMAN \
      -D__wasilibc_printscan_no_long_double \
      -D__wasilibc_printscan_no_floating_point \
      -D__BUILDING_LIBCSOUND \
      -DWASM_BUILD=1 ${preprocFlags} -c \
      unsupported_opcodes.c \
      ../Engine/auxfd.c \
      ../Engine/cfgvar.c \
      ../Engine/corfiles.c \
      ../Engine/cs_new_dispatch.c \
      ../Engine/cs_par_base.c \
      ../Engine/cs_par_orc_semantic_analysis.c \
      ../Engine/csound_data_structures.c \
      ../Engine/csound_orclex.c \
      ../Engine/csound_orc_compile.c \
      ../Engine/csound_orc_expressions.c \
      ../Engine/csound_orc_optimize.c \
      ../Engine/csound_orc_semantics.c \
      ../Engine/csound_orcparse.c \
      ../Engine/csound_prelex.c \
      ../Engine/csound_prslex.c \
      ../Engine/csound_standard_types.c \
      ../Engine/csound_type_system.c \
      ../Engine/entry1.c \
      ../Engine/envvar.c \
      ../Engine/extract.c \
      ../Engine/fgens.c \
      ../Engine/insert.c \
      ../Engine/linevent.c \
      ../Engine/memalloc.c \
      ../Engine/memfiles.c \
      ../Engine/musmon.c \
      ../Engine/namedins.c \
      ../Engine/new_orc_parser.c \
      ../Engine/pools.c \
      ../Engine/rdscor.c \
      ../Engine/scope.c \
      ../Engine/scsort.c \
      ../Engine/scxtract.c \
      ../Engine/sort.c \
      ../Engine/sread.c \
      ../Engine/swritestr.c \
      ../Engine/symbtab.c \
      ../Engine/symbtab.c \
      ../Engine/twarp.c \
      ../InOut/circularbuffer.c \
      ../InOut/libmpadec/layer1.c \
      ../InOut/libmpadec/layer2.c \
      ../InOut/libmpadec/layer3.c \
      ../InOut/libmpadec/mp3dec.c \
      ../InOut/libmpadec/mpadec.c \
      ../InOut/libmpadec/synth.c \
      ../InOut/libmpadec/tables.c \
      ../InOut/libsnd.c \
      ../InOut/libsnd_u.c \
      ../InOut/midifile.c \
      ../InOut/midirecv.c \
      ../InOut/midisend.c \
      ../InOut/winEPS.c \
      ../InOut/winascii.c \
      ../InOut/windin.c \
      ../InOut/window.c \
      ../OOps/aops.c \
      ../OOps/bus.c \
      ../OOps/cmath.c \
      ../OOps/compile_ops.c \
      ../OOps/diskin2.c \
      ../OOps/disprep.c \
      ../OOps/dumpf.c \
      ../OOps/fftlib.c \
      ../OOps/goto_ops.c \
      ../OOps/lpred.c \
      ../OOps/midiinterop.c \
      ../OOps/midiops.c \
      ../OOps/midiout.c \
      ../OOps/mxfft.c \
      ../OOps/oscils.c \
      ../OOps/pffft.c \
      ../OOps/pstream.c \
      ../OOps/pvfileio.c \
      ../OOps/pvsanal.c \
      ../OOps/random.c \
      ../OOps/remote.c \
      ../OOps/schedule.c \
      ../OOps/sndinfUG.c \
      ../OOps/str_ops.c \
      ../OOps/ugens1.c \
      ../OOps/ugens2.c \
      ../OOps/ugens3.c \
      ../OOps/ugens4.c \
      ../OOps/ugens5.c \
      ../OOps/ugens6.c \
      ../OOps/ugrw1.c \
      ../OOps/ugtabs.c \
      ../OOps/vdelay.c \
      ../Opcodes/Vosim.c \
      ../Opcodes/afilters.c \
      ../Opcodes/ambicode.c \
      ../Opcodes/ambicode1.c \
      ../Opcodes/arrays.c \
      ../Opcodes/babo.c \
      ../Opcodes/bbcut.c \
      ../Opcodes/bilbar.c \
      ../Opcodes/biquad.c \
      ../Opcodes/bowedbar.c \
      ../Opcodes/buchla.c \
      ../Opcodes/butter.c \
      ../Opcodes/cellular.c \
      ../Opcodes/clfilt.c \
      ../Opcodes/compress.c \
      ../Opcodes/cpumeter.c \
      ../Opcodes/cross2.c \
      ../Opcodes/crossfm.c \
      ../Opcodes/dam.c \
      ../Opcodes/date.c \
      ../Opcodes/dcblockr.c \
      ../Opcodes/dsputil.c \
      ../Opcodes/emugens/beosc.c \
      ../Opcodes/emugens/emugens.c \
      ../Opcodes/emugens/scugens.c \
      ../Opcodes/eqfil.c \
      ../Opcodes/exciter.c \
      ../Opcodes/fareygen.c \
      ../Opcodes/fareyseq.c \
      ../Opcodes/filter.c \
      ../Opcodes/flanger.c \
      ../Opcodes/fm4op.c \
      ../Opcodes/follow.c \
      ../Opcodes/fout.c \
      ../Opcodes/framebuffer/Framebuffer.c \
      ../Opcodes/framebuffer/OLABuffer.c \
      ../Opcodes/framebuffer/OpcodeEntries.c \
      ../Opcodes/freeverb.c \
      ../Opcodes/ftconv.c \
      ../Opcodes/ftest.c \
      ../Opcodes/ftgen.c \
      ../Opcodes/gab/gab.c \
      ../Opcodes/gab/hvs.c \
      ../Opcodes/gab/newgabopc.c \
      ../Opcodes/gab/sliderTable.c \
      ../Opcodes/gab/tabmorph.c \
      ../Opcodes/gab/vectorial.c \
      ../Opcodes/gammatone.c \
      ../Opcodes/gendy.c \
      ../Opcodes/getftargs.c \
      ../Opcodes/grain.c \
      ../Opcodes/grain4.c \
      ../Opcodes/harmon.c \
      ../Opcodes/hrtfearly.c \
      ../Opcodes/hrtferX.c \
      ../Opcodes/hrtfopcodes.c \
      ../Opcodes/hrtfreverb.c \
      ../Opcodes/ifd.c \
      ../Opcodes/liveconv.c \
      ../Opcodes/locsig.c \
      ../Opcodes/loscilx.c \
      ../Opcodes/lowpassr.c \
      ../Opcodes/mandolin.c \
      ../Opcodes/metro.c \
      ../Opcodes/midiops2.c \
      ../Opcodes/midiops3.c \
      ../Opcodes/minmax.c \
      ../Opcodes/modal4.c \
      ../Opcodes/modmatrix.c \
      ../Opcodes/moog1.c \
      ../Opcodes/mp3in.c \
      ../Opcodes/newfils.c \
      ../Opcodes/nlfilt.c \
      ../Opcodes/oscbnk.c \
      ../Opcodes/pan2.c \
      ../Opcodes/partials.c \
      ../Opcodes/partikkel.c \
      ../Opcodes/paulstretch.c \
      ../Opcodes/phisem.c \
      ../Opcodes/physmod.c \
      ../Opcodes/physutil.c \
      ../Opcodes/pinker.c \
      ../Opcodes/pitch.c \
      ../Opcodes/pitch0.c \
      ../Opcodes/pitchtrack.c \
      ../Opcodes/platerev.c \
      ../Opcodes/pluck.c \
      ../Opcodes/psynth.c \
      ../Opcodes/pvadd.c \
      ../Opcodes/pvinterp.c \
      ../Opcodes/pvlock.c \
      ../Opcodes/pvoc.c \
      ../Opcodes/pvocext.c \
      ../Opcodes/pvread.c \
      ../Opcodes/pvs_ops.c \
      ../Opcodes/pvsband.c \
      ../Opcodes/pvsbasic.c \
      ../Opcodes/pvsbuffer.c \
      ../Opcodes/pvscent.c \
      ../Opcodes/pvsdemix.c \
      ../Opcodes/pvsgendy.c \
      ../Opcodes/quadbezier.c \
      ../Opcodes/repluck.c \
      ../Opcodes/reverbsc.c \
      ../Opcodes/scansyn.c \
      ../Opcodes/scansynx.c \
      ../Opcodes/scoreline.c \
      ../Opcodes/select.c \
      ../Opcodes/seqtime.c \
      ../Opcodes/sfont.c \
      ../Opcodes/shaker.c \
      ../Opcodes/shape.c \
      ../Opcodes/singwave.c \
      ../Opcodes/sndloop.c \
      ../Opcodes/sndwarp.c \
      ../Opcodes/space.c \
      ../Opcodes/spat3d.c \
      ../Opcodes/spectra.c \
      ../Opcodes/squinewave.c \
      ../Opcodes/stackops.c \
      ../Opcodes/stdopcod.c \
      ../Opcodes/syncgrain.c \
      ../Opcodes/tabaudio.c \
      ../Opcodes/tabsum.c \
      ../Opcodes/tl/sc_noise.c \
      ../Opcodes/ugakbari.c \
      ../Opcodes/ugens7.c \
      ../Opcodes/ugens8.c \
      ../Opcodes/ugens9.c \
      ../Opcodes/ugensa.c \
      ../Opcodes/uggab.c \
      ../Opcodes/ugmoss.c \
      ../Opcodes/ugnorman.c \
      ../Opcodes/ugsc.c \
      ../Opcodes/urandom.c \
      ../Opcodes/vaops.c \
      ../Opcodes/vbap.c \
      ../Opcodes/vbap1.c \
      ../Opcodes/vbap_n.c \
      ../Opcodes/vbap_zak.c \
      ../Opcodes/vpvoc.c \
      ../Opcodes/wave-terrain.c \
      ../Opcodes/wterrain2.c \
      ../Opcodes/wpfilters.c \
      ../Opcodes/zak.c \
      ../Top/argdecode.c \
      ../Top/cscore_internal.c \
      ../Top/cscorfns.c \
      ../Top/csdebug.c \
      ../Top/csmodule.c \
      ../Top/getstring.c \
      ../Top/main.c \
      ../Top/new_opts.c \
      ../Top/one_file.c \
      ../Top/opcode.c \
      ../Top/threads.c \
      ../Top/threadsafe.c \
      ../Top/utility.c \
      ../Top/csound.c \
      ../Opcodes/ampmidid.cpp \
      ../Opcodes/doppler.cpp \
      ../Opcodes/tl/fractalnoise.cpp \
      ../Opcodes/mixer.cpp \
      ../Opcodes/signalflowgraph.cpp \
      ../Opcodes/pvsops.cpp \
      csound_wasm.c

    #TODO fix ../Opcodes/ftsamplebank.cpp (why does it import thread-local?)
    ${if (static == true) then static-link else dyn-link}

    echo "Archiving the objects"
    ${wasi-sdk}/bin/llvm-ar crS libcsound.a ./*.o
    ${wasi-sdk}/bin/llvm-ranlib -U libcsound.a
  '';

  installPhase = ''
    mkdir -p $out/lib
    mkdir -p $out/include
    cp ./libcsound.wasm $out/lib
    cp -rf ../H $out/include
    cp -rf ../Engine $out/include
    cp -rf ../include/* $out/include

    # # make a compressed version for the browser bundle
    ${pkgs.zopfli}/bin/zopfli --zlib -c \
      $out/lib/libcsound.wasm > $out/lib/libcsound.wasm.zlib
    cp libcsound.a $out/lib
  '';
}
