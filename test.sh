#!/bin/bash
curl -X POST http://localhost:8080/api/login \
  -H "Content-Type: application/json" \
  -d '{"username":"SarahRose","password":"Srl097130!"}'
