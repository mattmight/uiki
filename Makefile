
.PHONY: run 
run: config.rkt db docroot passwd
	racket uiki.rkt 

db:
	mkdir db
	mkdir db/main
	cp -v resources/content.md db/main/

passwd:
	echo 'Enter a password for the user `admin`':
	@htpasswd -sc passwd admin

docroot:
	mkdir docroot
	cp -v resources/test.html docroot/

certs:
	mkdir certs
	cd certs; openssl req  -nodes -new -x509 -keyout private-key.pem -out server-cert.pem; chmod 400 private-key.pem

.PHONY: runroot
runroot: config.rkt db docroot
	sudo racket uiki.rkt

config.rkt: config.rkt.default
	cp -v config.rkt.default config.rkt

