SRC = $(wildcard *.src)
REF = $(patsubst %.src,%.ref,$(SRC))

%.ref: %.src ../mdp
	../mdp $< $@

test: $(REF)
	git diff --exit-code -- *.ref
