#!/usr/bin/env bash
# rapidgzip 0.14.5 output bytes on padded / garbage-tailed members, by -P (vs GNU gzip).
set +e
echo "flags $-; nproc $(sysctl -n hw.ncpu)"
PY=/tmp/ak2-48-tools/rg-venv-empty/venv/bin/python
CLI="import sys; from rapidgzip import cli; sys.argv[0] = 'rapidgzip'; sys.exit(cli())"
R=/Users/scttfrdmn/src/aws-kraken2/.cache/reads
W=/tmp/ak2-48-work/rgP; mkdir -p $W
{ cat $R/SRR062634_200000_1.fq.gz; head -c 4096 /dev/zero; } > $W/s1.zeropad.gz
{ cat $R/SRR062634_200000_1.fq.gz; printf 'trailing garbage\n'; } > $W/s1.garbage.gz
{ cat $R/ERR478965_200000_1.fq.gz; printf 'trailing garbage\n'; } > $W/s2.garbage.gz
printf 'file\tgnu_bytes\tP\trapidgzip_bytes\tlost\n'
for f in s1.zeropad.gz s1.garbage.gz s2.garbage.gz; do
  g=$(/tmp/gnugzip/inst/bin/gzip -dc $W/$f 2>/dev/null | wc -c | tr -d ' ')
  for p in default 1 2 4 8 16; do
    if [ $p = default ]; then a=(); else a=(-P $p); fi
    for rep in 1 2; do
      n=$("$PY" -I -c "$CLI" -d -c "${a[@]}" $W/$f 2>/dev/null | wc -c | tr -d ' ')
      printf '%s\t%s\t%s\t%s\t%s\n' $f $g $p $n $((g - n))
    done
  done
done
