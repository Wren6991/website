SRC = $(wildcard *.src)
REF = $(patsubst %.src,%.ref,$(SRC))
.PHONY: clean test

%.ref: %.src ../mdp
	../mdp $< -o $@

test: $(REF)
	git diff --exit-code -- *.ref

clean:
	rm *.ref
