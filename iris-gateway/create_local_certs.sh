#!/bin/bash
# Script to generate a self-signed certificate and private key for the domain "garden.local" on LAN

set -e

DOMAIN="garden.local"
DAYS=365

echo "Generating private key..."
openssl genrsa -out privkey.pem 2048

echo "Creating OpenSSL config file for SAN..."
cat > ${DOMAIN}.cnf <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[dn]
C=US
ST=State
L=City
O=GardenOrg
OU=GardenLAN
CN=${DOMAIN}

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1   = ${DOMAIN}
EOF

echo "Generating certificate signing request (CSR)..."
openssl req -new -key privkey.pem -out ${DOMAIN}.csr -config ${DOMAIN}.cnf

echo "Generating self-signed certificate..."
openssl x509 -req -in ${DOMAIN}.csr -signkey privkey.pem -out cert.pem -days ${DAYS} -extensions req_ext -extfile ${DOMAIN}.cnf

echo "Creating fullchain file..."
cp cert.pem fullchain.pem

echo "Cleaning up intermediate files..."
rm -f ${DOMAIN}.csr ${DOMAIN}.cnf

echo "Done!"
echo "Files generated:"
echo "  - Private Key:     privkey.pem"
echo "  - Certificate:     cert.pem"
echo "  - Fullchain:       fullchain.pem"