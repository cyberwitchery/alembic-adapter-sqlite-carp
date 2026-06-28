CARP ?= carp
BIN  := alembic-adapter-sqlite
SRC  := alembic-sqlite.carp

$(BIN): $(SRC)
	$(CARP) -b $(SRC)
	cp out/$(BIN) ./$(BIN)

.PHONY: optimize clean
optimize: $(SRC)
	$(CARP) --optimize -b $(SRC)
	cp out/$(BIN) ./$(BIN)

clean:
	rm -rf out $(BIN)
