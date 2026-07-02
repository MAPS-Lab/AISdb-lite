#!/bin/bash
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
ROOTDIR="${SCRIPTPATH}/.."
PKGDIR="${ROOTDIR}/aisdb"
RSTSOURCEDIR="${ROOTDIR}/docs/source"
SPHINXDIR="${ROOTDIR}/docs/dist_sphinx"
#COVERAGEDIR="${ROOTDIR}/docs/dist_coverage"

set -e

# sphinx docs site build
cd "${ROOTDIR}"
rm -rf "$SPHINXDIR"
[[ -d "${RSTSOURCEDIR}/api" ]] && rm ${RSTSOURCEDIR}/api/*
mkdir -p "${RSTSOURCEDIR}/api"
mkdir -p "${SPHINXDIR}/_images"
cp "$ROOTDIR/docs/changelog.rst" "${RSTSOURCEDIR}/changelog.rst"
export SPHINXDOC=1 && sphinx-apidoc --separate --force --implicit-namespaces --module-first --no-toc -o "${RSTSOURCEDIR}/api" "${PKGDIR}" ${PKGDIR}/tests/*
python -m sphinx -a -j auto -q -b=html "${RSTSOURCEDIR}" "${SPHINXDIR}"
