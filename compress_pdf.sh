#!/bin/bash
small_file=${1%.pdf}_small.pdf
jpg_file=${1%.pdf}.jpg
gs -sDEVICE=pdfwrite -dUseCIEColor -dCompatibilityLevel=1.4 -dPDFSETTINGS=/printer -dNOPAUSE -dQUIET -dBATCH -sOutputFile=${small_file} $1
convert -density 300  -quality 90 -flatten ${small_file} ${jpg_file}