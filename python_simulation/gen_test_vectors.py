import random
from ascon import ascon_hash, ascon_encrypt, ascon_decrypt

def gen_vectors():
    num_tests = 100
    
    with open("hash_tv.txt", "w") as f:
        for i in range(num_tests):
            msg_len = random.randint(0, 64)
            msg = bytes([random.randint(0, 255) for _ in range(msg_len)])
            tag = ascon_hash(msg, "Ascon-Hash256", 32)
            
            f.write(f"{msg_len}\n")
            if msg_len > 0:
                for j in range(0, msg_len, 8):
                    chunk = msg[j:j+8]
                    chunk = chunk + b'\x00'*(8-len(chunk))
                    f.write(f"{int.from_bytes(chunk, 'big'):016x}\n")
            else:
                f.write(f"{0:016x}\n")
            # Write tag in 4 chunks of 64 bits
            for j in range(0, 32, 8):
                chunk = tag[j:j+8]
                f.write(f"{int.from_bytes(chunk, 'big'):016x}\n")

    def write_aead_vectors(filename, mode_encrypt):
        with open(filename, "w") as f:
            for i in range(num_tests):
                key = bytes([random.randint(0, 255) for _ in range(16)])
                nonce = bytes([random.randint(0, 255) for _ in range(16)])
                ad_len = random.randint(0, 64)
                ad = bytes([random.randint(0, 255) for _ in range(ad_len)])
                pt_len = random.randint(0, 64)
                pt = bytes([random.randint(0, 255) for _ in range(pt_len)])
                
                res = ascon_encrypt(key, nonce, ad, pt)
                ct = res[:pt_len]
                tag = res[pt_len:]
                
                f.write(f"{key.hex()}\n")
                f.write(f"{nonce.hex()}\n")
                f.write(f"{ad_len}\n")
                
                # AD blocks
                num_ad_blocks = (ad_len // 16) + 1
                for j in range(num_ad_blocks):
                    chunk = ad[j*16 : (j+1)*16]
                    chunk = chunk + b'\x00'*(16-len(chunk))
                    f.write(f"{int.from_bytes(chunk, 'big'):032x}\n")
                
                f.write(f"{pt_len}\n")
                if mode_encrypt:
                    # PT blocks
                    num_pt_blocks = (pt_len // 16) + 1
                    for j in range(num_pt_blocks):
                        p_chunk = pt[j*16 : (j+1)*16]
                        p_chunk = p_chunk + b'\x00'*(16-len(p_chunk))
                        f.write(f"{int.from_bytes(p_chunk, 'big'):032x}\n")
                    # Expected CT blocks
                    for j in range(num_pt_blocks):
                        c_chunk = ct[j*16 : (j+1)*16]
                        c_chunk = c_chunk + b'\x00'*(16-len(c_chunk))
                        f.write(f"{int.from_bytes(c_chunk, 'big'):032x}\n")
                    f.write(f"{tag.hex()}\n")
                else:
                    # CT blocks
                    num_pt_blocks = (pt_len // 16) + 1
                    for j in range(num_pt_blocks):
                        c_chunk = ct[j*16 : (j+1)*16]
                        c_chunk = c_chunk + b'\x00'*(16-len(c_chunk))
                        f.write(f"{int.from_bytes(c_chunk, 'big'):032x}\n")
                    f.write(f"{tag.hex()}\n")
                    # Expected PT blocks
                    for j in range(num_pt_blocks):
                        p_chunk = pt[j*16 : (j+1)*16]
                        p_chunk = p_chunk + b'\x00'*(16-len(p_chunk))
                        f.write(f"{int.from_bytes(p_chunk, 'big'):032x}\n")
                    # Valid tag ref (for decrypt testbench)
                    f.write(f"{tag.hex()}\n")

    write_aead_vectors("encrypt_tv.txt", True)
    write_aead_vectors("decrypt_tv.txt", False)

if __name__ == "__main__":
    gen_vectors()
