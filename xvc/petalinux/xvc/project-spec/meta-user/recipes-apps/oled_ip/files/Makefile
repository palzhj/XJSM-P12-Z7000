APP = oled_ip
CFLAGS += -O2 -Wall

all: $(APP)

$(APP): $(APP).c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f $(APP)
