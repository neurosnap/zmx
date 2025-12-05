#!/bin/bash

# transmit a PNG (format=100 → PNG)
data=$(base64 -w0 ./logo.png)
printf '\033_Ga=T,f=100;%s\033\\' "$data"
