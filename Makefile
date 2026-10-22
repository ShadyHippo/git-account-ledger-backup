IMAGE ?= ghcr.io/shadyhippo/git-account-ledger-backup
TAG   ?= latest

.PHONY: test build push release

test:
	bash tests/test-backup.sh

build:
	buildah bud -t $(IMAGE):$(TAG) .

push:
	buildah push $(IMAGE):$(TAG)

release: test build push
