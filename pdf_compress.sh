#!/bin/bash
small_file=${1%.pdf}_small.pdf
base=${1%.pdf}
gs -sDEVICE=pdfwrite -dUseCIEColor -dCompatibilityLevel=1.4 -dPDFSETTINGS=/printer -dNOPAUSE -dQUIET -dBATCH -sOutputFile=${small_file} $1
#pdftoppm -jpeg -r 75 ${small_file} ${base}_75dpi
#pdftoppm -jpeg -r 150 ${small_file} ${base}_150dpi
#pdftoppm -jpeg -r 300 ${small_file} ${base}_300dpi
