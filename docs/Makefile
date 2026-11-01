clean:
	rm -rf ./public/*
.PHONY: clean

ssg:
	go run ./main.go
	cp ./static/* ../logo.png ./public/
.PHONY: ssg

dev: ssg
	rsync -vr --delete ./public/ pgs.sh:/zmx-local
.PHONY: dev

prod: ssg
	rsync -vr ./public/ pgs.sh:/zmx
.PHONY: prod
