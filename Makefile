ifndef MEMALLOY_ROOT_DIR
$(error Please run 'source configure.sh')
endif

.PHONY: all quickbuild fullbuild clean fullclean quicktest moretests slowtests

#BINARIES = gen cat2als pp_comparator xml2soln
BINARIES = xml2soln compare_solns

quickbuild:
	$(foreach DIR,$(BINARIES),make -C $(DIR) clean;)
	$(foreach DIR,$(BINARIES),make -C $(DIR);)

fullbuild:
	git submodule update --init --recursive
	make -C alloystar
	make quickbuild

quicktest: 
	@ tests/Q2_c11_lidbury_partial.sh

moretests:
	tests/Q2_sc_x86.sh
	tests/Q2_c11_lidbury_partial.sh
	tests/Q2_c11_sra_simp.sh
	tests/Q2_c11_swrf_simp.sh
	tests/Q2_c11_simp_orig.sh
	tests/Q2_c11_simp_orig2.sh
	tests/Q2_sc_c11nodrf.sh
	tests/Q2_ppc_mca.sh
	tests/Q2_c11_repairing0.sh
	tests/Q2_c11_repairing1.sh
	tests/Q2_c11_repairing2.sh
	tests/Q2_c11_repairing3.sh
	tests/Q2_c11_repairing4.sh
	tests/Q2_c11_repairing5.sh
	tests/Q4_c11_ppc.sh
	tests/Q4_c11_arm7.sh
	tests/Q4_opencl_ptx_orig.sh
	tests/Q4_opencl_ptx_cumul.sh
	tests/Q2_x86_mca.sh
	tests/Q2_c11_sra_simp_iter.sh
	tests/Q4_ocaml_ppc_v1.sh
	tests/Q4_ocaml_ppc_v2.sh

slowtests:
	tests/Q2_c11_lidbury_partial_iter.sh
	tests/Q2_ptx.sh

clean:
	python etc/rm_als.py
	rm -f comparator.als
	$(foreach DIR,$(BINARIES),make -C $(DIR) clean;)

fullclean: clean
	make -C alloystar clean
