import ascon

key = bytes.fromhex("d9c39c6b8f3894361adc8a678229d681")
nonce = bytes.fromhex("98c7235a460f5be1da6f9ffa23080280")
version = 1
a = 12
b = 8
rate = 16
taglen = 128
iv = ascon.to_bytes([version, 0, (b<<4) + a]) + ascon.int_to_bytes(taglen, 2) + ascon.to_bytes([rate, 0, 0])
S = ascon.bytes_to_state(iv + key + nonce)
print(f"S0: {S[0]:016x}")
print(f"S1: {S[1]:016x}")
print(f"S2: {S[2]:016x}")
print(f"S3: {S[3]:016x}")
print(f"S4: {S[4]:016x}")
