# Black magic to get module directories
modules := $(foreach initpy, $(foreach dir, $(wildcard lib/*), $(wildcard $(dir)/__init__.py)), $(realpath $(dir $(initpy))))

help:
	@echo "Streamlit Make Commands:"
	@echo " init         - Run once to install python and js dependencies."
	@echo " build        - build the static version of Streamlit (without Node)"
	@echo " protobuf     - Recompile Protobufs for Python and Javascript."
	@echo " develop      - Install streamlit pointing to local workspace."
	@echo " install      - Install streamlit pointing to PYTHONPATH."
	@echo " wheel        - Create a wheel file in dist/."
	@echo " loc          - Count lines of code."
	@echo " clean-docs   - Deletes the autogenerated HTML documentation."
	@echo " docs         - Generates HTML documentation at /docs/_build."
	@echo " publish-docs - Builds and pushes the documentation to prod."
	@echo " site         - Builds the site at /site/public."
	@echo " devel-site   - Starts the dev server for the site."
	@echo " publish-site - Builds and pushes the site to prod."
	@echo " pytest       - Runs unittests"

.PHONY: init
init: setup pipenv react-init protobuf # react-build release

.PHONY: build
build: react-build

setup:
	pip install pip-tools pipenv

PY_VERSION := $(shell python -c 'import platform; print(platform.python_version())')
ANACONDA_VERSION := $(shell ./scripts/anaconda_version.sh only)
ifdef ANACONDA_VERSION
PY_VERSION := $(ANACONDA_VERSION)
else
PY_VERSION := python-$(PY_VERSION)
endif

pipenv: lib/Pipfile
# In CircleCI, dont generate Pipfile.lock This is only used for development.
ifndef CIRCLECI
	cd lib; rm -f Pipfile.lock; pipenv lock --dev && mv Pipfile.lock Pipfile.locks/$(PY_VERSION)
else
	echo "Running in CircleCI, not generating requirements."
endif
	cd lib; rm -f Pipfile.lock; cp -f Pipfile.locks/$(PY_VERSION) Pipfile.lock
ifndef CIRCLECI
	# Dont update lockfile and install whatever is in lock.
	cd lib; pipenv install --ignore-pipfile --dev
else
	cd lib; pipenv install --ignore-pipfile --dev --system
endif

pylint:
	# Linting
	# (Ignore E402 since our Python2-compatibility imports break this lint rule.)
	cd lib; flake8 --ignore=E402,E128 --exclude=streamlit/protobuf/*_pb2.py $(modules) tests/

pytest:
	# Just testing. No code coverage.
	cd lib; PYTHONPATH=. pytest -v -l tests/ $(modules)

pycoverage:
	# testing + code coverage
	cd lib; PYTHONPATH=. pytest -v -l $(foreach dir,$(modules),--cov=$(dir)) --cov-report=term-missing tests/ $(modules)

install:
	cd lib ; python setup.py install

develop:
	cd lib ; python setup.py develop

# dev:
# 	python setup.py egg_info --tag-build=.$(USER) bdist_wheel sdist
# 	@echo
# 	@echo Dev wheel file in $(shell ls dist/*$(shell python setup.py --version).$(USER)-py27*whl) and install with '"pip install [wheel file]"'
# 	@echo

wheel:
	# Get rid of the old build folder to make sure that we delete old js and css.
	rm -rfv lib/build
	cd lib ; python setup.py bdist_wheel --universal
	# cd lib ; python setup.py bdist_wheel sdist

clean:
	@echo FIXME: This needs to be fixed!
	cd lib; rm -rf build dist  .eggs *.egg-info
	find . -name '*.pyc' -type f -delete || true
	find . -name __pycache__ -type d -delete || true
	find . -name .pytest_cache -exec rm -rfv {} \; || true
	cd frontend; rm -rf build node_modules
	rm -f lib/streamlit/protobuf/*_pb2.py
	rm -f frontend/src/protobuf.js
	rm -rf lib/streamlit/static
	find . -name .streamlit -type d -exec rm -rfv {} \; || true
	cd lib; rm -rf .coverage .coverage\.*

.PHONY: clean-docs
clean-docs:
	cd docs; \
		make distclean

.PHONY: docs
docs: clean-docs
	cd docs; \
		make html

.PHONY: devel-docs
devel-docs: docs
	cd docs/_build/html; \
		python -m SimpleHTTPServer 8000 || python -m http.server 8000

.PHONY: publish-docs
publish-docs: docs
	cd docs/_build; \
		aws s3 sync \
				--acl public-read html s3://streamlit.io/secret/docs/ \
				--profile streamlit

.PHONY: site
site:
	cd site; hugo

.PHONY: devel-site
devel-site:
	cd site; hugo server -D

.PHONY: publish-site
publish-site: site
	cd site; \
		hugo; \
		rm public/secret/index.*; \
		aws s3 sync \
				--acl public-read public s3://streamlit.io/ \
				--profile streamlit

.PHONY: protobuf
protobuf:
	protoc \
				--proto_path=protobuf protobuf/*.proto \
				--python_out=lib/streamlit/protobuf
	cd frontend/ ; ( \
		echo "/* eslint-disable */" ; \
		echo ; \
		./node_modules/protobufjs/bin/pbjs ../protobuf/*.proto -t static-module \
	) > ./src/protobuf.js

.PHONY: react-init
react-init:
	cd frontend/ ; npm install

.PHONY: react-build
react-build:
	cd frontend/ ; npm run build
	rsync -av --delete --delete-excluded --exclude=reports \
		frontend/build/ lib/streamlit/static/
	find lib/streamlit/static -type 'f' -iname '*.map' | xargs rm -fv

js-lint:
	cd frontend; ./node_modules/.bin/eslint src

js-test:
	cd frontend; npm run test
	cd frontend; npm run coverage


# Counts the number of lines of code in the project
loc:
	find . -iname '*.py' -or -iname '*.js'  | \
		egrep -v "(node_modules)|(_pb2)|(lib\/protobuf)|(dist\/)" | \
		xargs wc

# Distributes the package to PyPi
distribute:
	cd lib/dist; \
		twine upload $$(ls -t *.whl | head -n 1)

.PHONY: docker-build-frontend
docker-build-frontend:
	cd docker/streamlit ; docker-compose build frontend
