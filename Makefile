IMAGE ?= ghcr.io/shadyhippo/git-account-ledger-backup
TAG   ?= latest

.PHONY: test test-unit test-adversarial build push release

test: test-unit test-adversarial

test-unit:
	bash tests/test-backup.sh

test-adversarial:
	bash tests/test-adversarial.sh

build:
	buildah bud --format docker -t $(IMAGE):$(TAG) .

push:
	buildah push $(IMAGE):$(TAG)

release: test build push
