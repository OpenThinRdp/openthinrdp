using System;
using System.IO;
using System.Text;
using System.Numerics;
using System.Security.Cryptography;

// The vault of the manager and the signature of the update packages, without anything installed on the PC.
//   Ed25519 (RFC 8032): .NET Framework has no Ed25519, so it is written here (slow BigInteger arithmetic, a
//   few milliseconds for one signature, enough for a tool that signs one file at a time).
//   OpenPGP (RFC 4880 + EdDSA of draft-koch / RFC 9580 "legacy" EdDSA, algorithm 22): reading the secret key
//   exported by gpg (--export-secret-keys, without a passphrase) and the detached signature that gpg
//   --detach-sign writes and sqv/gpgv check on the devices.
//   Vault: PBKDF2-HMAC-SHA256 (600000 rounds) of the access code -> AES-256-CBC + HMAC-SHA256 (encrypt then MAC).
public static class OtrVault {
    // ---------------- Ed25519 ----------------
    static readonly BigInteger P = BigInteger.Pow(2, 255) - 19;
    static readonly BigInteger L = BigInteger.Pow(2, 252) + BigInteger.Parse("27742317777372353535851937790883648493");
    static readonly BigInteger D = Mod(-121665 * Inv(121666));
    static readonly BigInteger I = BigInteger.ModPow(2, (P - 1) / 4, P);
    static readonly BigInteger[] B = BasePoint();

    static BigInteger Mod(BigInteger a) { BigInteger r = a % P; return r.Sign < 0 ? r + P : r; }
    static BigInteger Inv(BigInteger a) { return BigInteger.ModPow(Mod(a), P - 2, P); }
    static BigInteger[] BasePoint() {
        BigInteger y = Mod(4 * Inv(5));
        BigInteger x = RecoverX(y, 0);
        return new BigInteger[] { x, y, BigInteger.One, Mod(x * y) };
    }
    // x from y and the sign bit; -1 when y is not on the curve
    static BigInteger RecoverX(BigInteger y, int sign) {
        if (y >= P) return BigInteger.MinusOne;
        BigInteger x2 = Mod((y * y - 1) * Inv(D * y * y + 1));
        if (x2.IsZero) return sign == 0 ? BigInteger.Zero : BigInteger.MinusOne;
        BigInteger x = BigInteger.ModPow(x2, (P + 3) / 8, P);
        if (!Mod(x * x - x2).IsZero) x = Mod(x * I);
        if (!Mod(x * x - x2).IsZero) return BigInteger.MinusOne;
        if ((int)(x & 1) != sign) x = P - x;
        return x;
    }
    // extended coordinates (X, Y, Z, T), the addition of RFC 8032 5.1.4 (also good for doubling)
    static BigInteger[] Add(BigInteger[] p, BigInteger[] q) {
        BigInteger a = Mod((p[1] - p[0]) * (q[1] - q[0])), b = Mod((p[1] + p[0]) * (q[1] + q[0]));
        BigInteger c = Mod(p[3] * 2 * D * q[3]), d = Mod(p[2] * 2 * q[2]);
        BigInteger e = b - a, f = d - c, g = d + c, h = b + a;
        return new BigInteger[] { Mod(e * f), Mod(g * h), Mod(f * g), Mod(e * h) };
    }
    static BigInteger[] Mul(BigInteger s, BigInteger[] p) {
        BigInteger[] q = new BigInteger[] { BigInteger.Zero, BigInteger.One, BigInteger.One, BigInteger.Zero };
        while (s.Sign > 0) { if (!s.IsEven) q = Add(q, p); p = Add(p, p); s >>= 1; }
        return q;
    }
    static byte[] Encode(BigInteger[] p) {
        BigInteger zi = Inv(p[2]), x = Mod(p[0] * zi), y = Mod(p[1] * zi);
        byte[] r = Le(y, 32);
        r[31] |= (byte)((int)(x & 1) << 7);
        return r;
    }
    static BigInteger[] Decode(byte[] s) {
        if (s == null || s.Length != 32) return null;
        byte[] c = (byte[])s.Clone(); int sign = c[31] >> 7; c[31] &= 0x7f;
        BigInteger y = FromLe(c), x = RecoverX(y, sign);
        if (x.Sign < 0) return null;
        return new BigInteger[] { x, y, BigInteger.One, Mod(x * y) };
    }
    static BigInteger FromLe(byte[] b) { byte[] t = new byte[b.Length + 1]; Buffer.BlockCopy(b, 0, t, 0, b.Length); return new BigInteger(t); }
    static byte[] Le(BigInteger v, int n) {
        byte[] b = v.ToByteArray(), r = new byte[n];
        Buffer.BlockCopy(b, 0, r, 0, Math.Min(b.Length, n));
        return r;
    }
    static byte[] Sha512(params byte[][] parts) {
        using (SHA512 h = SHA512.Create()) {
            foreach (byte[] p in parts) h.TransformBlock(p, 0, p.Length, null, 0);
            h.TransformFinalBlock(new byte[0], 0, 0);
            return h.Hash;
        }
    }
    static BigInteger Scalar(byte[] seed, out byte[] prefix) {
        if (seed == null || seed.Length != 32) throw new ArgumentException("an Ed25519 secret key is 32 bytes");
        byte[] h = Sha512(seed), a = new byte[32];
        Buffer.BlockCopy(h, 0, a, 0, 32);
        a[0] &= 248; a[31] &= 127; a[31] |= 64;
        prefix = new byte[32]; Buffer.BlockCopy(h, 32, prefix, 0, 32);
        return FromLe(a);
    }
    public static byte[] Ed25519Public(byte[] seed) { byte[] prefix; return Encode(Mul(Scalar(seed, out prefix), B)); }
    public static byte[] Ed25519Sign(byte[] seed, byte[] msg) {
        byte[] prefix; BigInteger a = Scalar(seed, out prefix);
        byte[] pub = Encode(Mul(a, B));
        BigInteger r = FromLe(Sha512(prefix, msg)) % L;
        byte[] R = Encode(Mul(r, B));
        BigInteger k = FromLe(Sha512(R, pub, msg)) % L;
        byte[] sig = new byte[64];
        Buffer.BlockCopy(R, 0, sig, 0, 32);
        Buffer.BlockCopy(Le((r + k * a) % L, 32), 0, sig, 32, 32);
        return sig;
    }
    public static bool Ed25519Verify(byte[] pub, byte[] msg, byte[] sig) {
        if (sig == null || sig.Length != 64) return false;
        BigInteger[] A = Decode(pub); if (A == null) return false;
        byte[] R = new byte[32], S = new byte[32];
        Buffer.BlockCopy(sig, 0, R, 0, 32); Buffer.BlockCopy(sig, 32, S, 0, 32);
        if (Decode(R) == null) return false;
        BigInteger s = FromLe(S); if (s >= L) return false;
        BigInteger k = FromLe(Sha512(R, pub, msg)) % L;
        byte[] left = Encode(Mul(s, B)), right = Encode(Add(Decode(R), Mul(k, A)));
        return Same(left, right);
    }
    static bool Same(byte[] a, byte[] b) {
        if (a == null || b == null || a.Length != b.Length) return false;
        int d = 0; for (int i = 0; i < a.Length; i++) d |= a[i] ^ b[i];
        return d == 0;
    }

    // ---------------- OpenPGP ----------------
    static readonly byte[] OidEd25519 = { 0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01 };
    public class SigningKey {
        public byte[] Seed, Public, Fingerprint; public uint Created; public string User;
        public string Hex() { return ToHex(Fingerprint).ToUpperInvariant(); }
    }
    public static string ToHex(byte[] b) { StringBuilder s = new StringBuilder(); foreach (byte x in b) s.Append(x.ToString("x2")); return s.ToString(); }
    public static byte[] FromHex(string h) {
        if (h == null || h.Length % 2 != 0) throw new FormatException("hex");
        byte[] r = new byte[h.Length / 2];
        for (int i = 0; i < r.Length; i++) r[i] = Convert.ToByte(h.Substring(2 * i, 2), 16);
        return r;
    }
    // the binary of an ASCII armor (the lines between the empty line after the header and the checksum)
    public static byte[] Dearmor(string text) {
        string[] lines = text.Replace("\r", "").Split('\n');
        int i = 0;
        while (i < lines.Length && !lines[i].StartsWith("-----BEGIN PGP ")) i++;
        if (i == lines.Length) throw new FormatException("not an OpenPGP armor");
        i++;
        while (i < lines.Length && lines[i].Trim().Length > 0) i++;   // header lines (Version:, Comment:...)
        StringBuilder b = new StringBuilder();
        for (i++; i < lines.Length; i++) {
            string l = lines[i].Trim();
            if (l.StartsWith("-----END") || (l.StartsWith("=") && l.Length == 5)) break;
            b.Append(l);
        }
        return Convert.FromBase64String(b.ToString());
    }
    // the packets of a binary OpenPGP message: tag and body
    static System.Collections.Generic.List<Tuple<int, byte[]>> Packets(byte[] m) {
        System.Collections.Generic.List<Tuple<int, byte[]>> r = new System.Collections.Generic.List<Tuple<int, byte[]>>();
        int i = 0;
        while (i < m.Length) {
            int ctb = m[i++], tag, len;
            if ((ctb & 0x80) == 0) throw new FormatException("not an OpenPGP packet");
            if ((ctb & 0x40) != 0) {
                tag = ctb & 0x3f; int o = m[i++];
                if (o < 192) len = o;
                else if (o < 224) len = ((o - 192) << 8) + m[i++] + 192;
                else if (o == 255) { len = (m[i] << 24) | (m[i + 1] << 16) | (m[i + 2] << 8) | m[i + 3]; i += 4; }
                else throw new FormatException("partial lengths are not supported");
            } else {
                tag = (ctb >> 2) & 0xf; int lt = ctb & 3;
                if (lt == 0) len = m[i++];
                else if (lt == 1) { len = (m[i] << 8) | m[i + 1]; i += 2; }
                else if (lt == 2) { len = (m[i] << 24) | (m[i + 1] << 16) | (m[i + 2] << 8) | m[i + 3]; i += 4; }
                else throw new FormatException("indeterminate lengths are not supported");
            }
            if (len < 0 || i + len > m.Length) throw new FormatException("truncated packet");
            byte[] body = new byte[len]; Buffer.BlockCopy(m, i, body, 0, len); i += len;
            r.Add(Tuple.Create(tag, body));
        }
        return r;
    }
    // an MPI at b[i]: its bytes (big endian, without the leading zeros) and the position after it
    static byte[] ReadMpi(byte[] b, ref int i) {
        int bits = (b[i] << 8) | b[i + 1], n = (bits + 7) / 8;
        if (i + 2 + n > b.Length) throw new FormatException("truncated MPI");
        byte[] v = new byte[n]; Buffer.BlockCopy(b, i + 2, v, 0, n); i += 2 + n;
        return v;
    }
    static byte[] Mpi(byte[] v) {
        int s = 0; while (s < v.Length - 1 && v[s] == 0) s++;
        int n = v.Length - s, bits = (n - 1) * 8, top = v[s];
        while (top > 0) { bits++; top >>= 1; }
        byte[] r = new byte[n + 2]; r[0] = (byte)(bits >> 8); r[1] = (byte)bits;
        Buffer.BlockCopy(v, s, r, 2, n);
        return r;
    }
    static byte[] Pad32(byte[] v) {
        if (v.Length > 32) throw new FormatException("value longer than 32 bytes");
        byte[] r = new byte[32]; Buffer.BlockCopy(v, 0, r, 32 - v.Length, v.Length); return r;
    }
    // The primary key of "gpg --export-secret-keys --armor <key>": Ed25519 (EdDSA legacy), not protected by a passphrase
    // (the vault protects it). The secret is checked against the public key.
    public static SigningKey ReadSecretKey(byte[] file) {
        SigningKey k = null;
        foreach (Tuple<int, byte[]> p in Packets(Binary(file))) {
            if (p.Item1 == 13 && k != null && k.User == null) k.User = Encoding.UTF8.GetString(p.Item2);
            if (p.Item1 != 5 || k != null) continue;
            byte[] b = p.Item2; int i = 0;
            if (b[i++] != 4) throw new FormatException("only version 4 keys are supported");
            uint created = (uint)((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]); i += 4;
            if (b[i++] != 22) throw new FormatException("the key is not Ed25519 (EdDSA)");
            int ol = b[i++]; byte[] oid = new byte[ol]; Buffer.BlockCopy(b, i, oid, 0, ol); i += ol;
            if (!Same(oid, OidEd25519)) throw new FormatException("the key is not Ed25519");
            byte[] q = ReadMpi(b, ref i);
            if (q.Length != 33 || q[0] != 0x40) throw new FormatException("unexpected public point");
            int pubEnd = i;
            if (b[i++] != 0) throw new FormatException("the key is protected by a passphrase: export it without (gpg --export-secret-keys with a key that has none)");
            int start = i; byte[] d = ReadMpi(b, ref i);
            int sum = 0; for (int j = start; j < i; j++) sum += b[j];
            if (i + 2 > b.Length || ((b[i] << 8) | b[i + 1]) != (sum & 0xffff)) throw new FormatException("checksum of the secret key is wrong");
            k = new SigningKey();
            k.Seed = Pad32(d); k.Public = new byte[32]; Buffer.BlockCopy(q, 1, k.Public, 0, 32); k.Created = created;
            byte[] pub = new byte[pubEnd]; Buffer.BlockCopy(b, 0, pub, 0, pubEnd);
            k.Fingerprint = Fingerprint(pub);
            if (!Same(Ed25519Public(k.Seed), k.Public)) throw new FormatException("the secret key does not match its public key");
        }
        if (k == null) throw new FormatException("no secret key in the file");
        return k;
    }
    // a key file as gpg writes it: armored (--armor) or binary
    static byte[] Binary(byte[] file) {
        string head = Encoding.ASCII.GetString(file, 0, Math.Min(file.Length, 512));
        return head.Contains("-----BEGIN PGP ") ? Dearmor(Encoding.ASCII.GetString(file)) : file;
    }
    // the fingerprints of the primary keys and subkeys of a public (or secret) key file, upper case hex
    public static string[] Fingerprints(byte[] file) {
        System.Collections.Generic.List<string> r = new System.Collections.Generic.List<string>();
        foreach (Tuple<int, byte[]> p in Packets(Binary(file))) {
            byte[] b = p.Item2;
            if ((p.Item1 != 6 && p.Item1 != 14 && p.Item1 != 5 && p.Item1 != 7) || b.Length < 6 || b[0] != 4) continue;
            int i = 6, end;
            if (b[5] == 22 || b[5] == 18 || b[5] == 19) { i += 1 + b[i]; }          // the OID of the curve
            int mpis = b[5] == 1 ? 2 : b[5] == 17 ? 4 : b[5] == 16 ? 3 : b[5] == 18 ? 2 : 1;
            for (int m = 0; m < mpis; m++) {
                if (b[5] == 18 && m == 1) { i += 1 + b[i]; continue; }              // the KDF parameters of ECDH
                ReadMpi(b, ref i);
            }
            end = i;
            byte[] pub = new byte[end]; Buffer.BlockCopy(b, 0, pub, 0, end);
            r.Add(ToHex(Fingerprint(pub)).ToUpperInvariant());
        }
        return r.ToArray();
    }
    static byte[] Fingerprint(byte[] pubBody) {
        byte[] h = new byte[3 + pubBody.Length]; h[0] = 0x99; h[1] = (byte)(pubBody.Length >> 8); h[2] = (byte)pubBody.Length;
        Buffer.BlockCopy(pubBody, 0, h, 3, pubBody.Length);
        using (SHA1 s = SHA1.Create()) return s.ComputeHash(h);
    }
    static byte[] Be32(uint v) { return new byte[] { (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v }; }
    static byte[] Cat(params byte[][] parts) {
        MemoryStream m = new MemoryStream(); foreach (byte[] p in parts) m.Write(p, 0, p.Length); return m.ToArray();
    }
    static byte[] Sha256(params byte[][] parts) {
        using (SHA256 h = SHA256.Create()) {
            foreach (byte[] p in parts) h.TransformBlock(p, 0, p.Length, null, 0);
            h.TransformFinalBlock(new byte[0], 0, 0);
            return h.Hash;
        }
    }
    // the hashed part of a v4 signature of type t by key fpr: issuer fingerprint and creation time first, in the
    // order gpg writes them, then the subpackets given (already encoded)
    static byte[] HashedPart(byte t, byte[] fpr, uint time, byte[] more) {
        byte[] sub = Cat(new byte[] { 22, 33, 4 }, fpr, new byte[] { 5, 2 }, Be32(time), more);
        return Cat(new byte[] { 4, t, 22, 10, (byte)(sub.Length >> 8), (byte)sub.Length }, sub);
    }
    static byte[] Digest(byte[] data, byte[] hashed) {
        uint n = (uint)hashed.Length;
        return Sha512(data, hashed, new byte[] { 4, 0xFF }, Be32(n));
    }
    // Detached signature of data, as "gpg --armor --detach-sign": SHA-512 (what gpg uses with Ed25519), created at time (seconds since 1970)
    public static byte[] SignDetachedBinary(SigningKey k, byte[] data, uint time) {
        return SignaturePacket(k, data, HashedPart(0x00, k.Fingerprint, time, new byte[0]));
    }
    // a signature packet over "hashed input, then the hashed part" (RFC 4880 5.2.4), by key k
    static byte[] SignaturePacket(SigningKey k, byte[] input, byte[] hashed) {
        byte[] digest = Digest(input, hashed);
        byte[] sig = Ed25519Sign(k.Seed, digest);
        byte[] R = new byte[32], S = new byte[32]; Buffer.BlockCopy(sig, 0, R, 0, 32); Buffer.BlockCopy(sig, 32, S, 0, 32);
        byte[] keyId = new byte[8]; Buffer.BlockCopy(k.Fingerprint, 12, keyId, 0, 8);
        byte[] unhashed = Cat(new byte[] { 9, 16 }, keyId);
        byte[] body = Cat(hashed, new byte[] { (byte)(unhashed.Length >> 8), (byte)unhashed.Length }, unhashed,
                          new byte[] { digest[0], digest[1] }, Mpi(R), Mpi(S));
        byte[] head = body.Length < 256 ? new byte[] { 0x88, (byte)body.Length } : new byte[] { 0x89, (byte)(body.Length >> 8), (byte)body.Length };
        return Cat(head, body);
    }
    public static string SignDetached(SigningKey k, byte[] data, uint time) { return Armor(SignDetachedBinary(k, data, time), "SIGNATURE"); }

    // ---- a new key, made here: the site key of an installation, never written anywhere but the vault ----
    // the public key packet body: version 4, creation time, EdDSA, the OID of Ed25519, the point (0x40 + 32 bytes)
    static byte[] PublicBody(byte[] pub, uint created) {
        return Cat(new byte[] { 4 }, Be32(created), new byte[] { 22, (byte)OidEd25519.Length }, OidEd25519, Mpi(Cat(new byte[] { 0x40 }, pub)));
    }
    public static SigningKey NewSigningKey(string user, uint created) {
        SigningKey k = new SigningKey();
        k.Seed = new byte[32];
        using (RandomNumberGenerator r = RandomNumberGenerator.Create()) r.GetBytes(k.Seed);
        k.Public = Ed25519Public(k.Seed); k.Created = created; k.User = user;
        k.Fingerprint = Fingerprint(PublicBody(k.Public, created));
        return k;
    }
    static byte[] Header(int tag, int len) {
        // old format packet header, as gpg writes keys: 1 or 2 length bytes
        return len < 256 ? new byte[] { (byte)(0x80 | (tag << 2)), (byte)len } : new byte[] { (byte)(0x81 | (tag << 2)), (byte)(len >> 8), (byte)len };
    }
    // The public half to give to the devices (update-key.asc): the key, its user ID and the self-signature that
    // binds them (positive certification 0x13: may certify and sign, SHA-512 and SHA-256 preferred). The same key
    // always gives the same file (Ed25519 is deterministic and the signature carries the creation time of the key).
    public static string ExportPublic(SigningKey k) {
        byte[] body = PublicBody(k.Public, k.Created), uid = Encoding.UTF8.GetBytes(k.User ?? "");
        byte[] more = Cat(new byte[] { 2, 27, 0x03 }, new byte[] { 3, 21, 10, 8 }, new byte[] { 2, 30, 0x01 });
        byte[] hashed = HashedPart(0x13, k.Fingerprint, k.Created, more);
        byte[] input = Cat(new byte[] { 0x99, (byte)(body.Length >> 8), (byte)body.Length }, body,
                           new byte[] { 0xB4 }, Be32((uint)uid.Length), uid);
        byte[] sig = SignaturePacket(k, input, hashed);
        return Armor(Cat(Header(6, body.Length), body, Header(13, uid.Length), uid, sig), "PUBLIC KEY BLOCK");
    }
    // the Ed25519 public points of the keys in a public key file (primary keys and subkeys), to check signatures
    public static byte[][] PublicPoints(byte[] file) {
        System.Collections.Generic.List<byte[]> r = new System.Collections.Generic.List<byte[]>();
        foreach (Tuple<int, byte[]> p in Packets(Binary(file))) {
            byte[] b = p.Item2;
            if ((p.Item1 != 6 && p.Item1 != 14) || b.Length < 7 || b[0] != 4 || b[5] != 22) continue;
            int i = 6, ol = b[i++]; byte[] oid = new byte[ol]; Buffer.BlockCopy(b, i, oid, 0, ol); i += ol;
            if (!Same(oid, OidEd25519)) continue;
            byte[] q = ReadMpi(b, ref i);
            if (q.Length != 33 || q[0] != 0x40) continue;
            byte[] pt = new byte[32]; Buffer.BlockCopy(q, 1, pt, 0, 32); r.Add(pt);
        }
        return r.ToArray();
    }
    // true = data carries a good signature (sig, armored) of one of the keys of the public key file
    public static bool VerifyWithKeyFile(byte[] keyFile, byte[] data, string sig) {
        foreach (byte[] pt in PublicPoints(keyFile)) if (VerifyDetached(pt, data, sig)) return true;
        return false;
    }
    public static string Armor(byte[] b, string what) {
        StringBuilder s = new StringBuilder();
        s.Append("-----BEGIN PGP ").Append(what).Append("-----\n\n");
        string t = Convert.ToBase64String(b);
        for (int i = 0; i < t.Length; i += 64) s.Append(t.Substring(i, Math.Min(64, t.Length - i))).Append('\n');
        uint crc = Crc24(b);
        s.Append('=').Append(Convert.ToBase64String(new byte[] { (byte)(crc >> 16), (byte)(crc >> 8), (byte)crc })).Append('\n');
        s.Append("-----END PGP ").Append(what).Append("-----\n");
        return s.ToString();
    }
    static uint Crc24(byte[] b) {
        uint crc = 0xB704CE;
        foreach (byte x in b) {
            crc ^= (uint)x << 16;
            for (int i = 0; i < 8; i++) { crc <<= 1; if ((crc & 0x1000000) != 0) crc ^= 0x1864CFB; }
        }
        return crc & 0xFFFFFF;
    }
    // true = a good signature of data by the key with this public point (any of the signatures in the file)
    public static bool VerifyDetached(byte[] pub, byte[] data, string armored) {
        foreach (Tuple<int, byte[]> p in Packets(Dearmor(armored))) {
            byte[] b = p.Item2;
            // a signature of a binary document (0x00) only: a key certification is no signature of data
            if (p.Item1 != 2 || b.Length < 6 || b[0] != 4 || b[1] != 0x00 || b[2] != 22) continue;
            int hl = (b[4] << 8) | b[5], i = 6 + hl;
            byte[] hashed = new byte[i]; Buffer.BlockCopy(b, 0, hashed, 0, i);
            byte[] digest;
            uint n = (uint)hashed.Length;
            if (b[3] == 8) digest = Sha256(data, hashed, new byte[] { 4, 0xFF }, Be32(n));
            else if (b[3] == 10) digest = Sha512(data, hashed, new byte[] { 4, 0xFF }, Be32(n));
            else continue;
            int ul = (b[i] << 8) | b[i + 1]; i += 2 + ul;
            if (b[i] != digest[0] || b[i + 1] != digest[1]) continue;
            i += 2;
            byte[] R = Pad32(ReadMpi(b, ref i)), S = Pad32(ReadMpi(b, ref i));
            if (Ed25519Verify(pub, digest, Cat(R, S))) return true;
        }
        return false;
    }
    // ---------------- vault ----------------
    public const int Rounds = 600000;
    // 32 bytes of PBKDF2 (one block: 64 would run the rounds twice), then the key of AES and the key of the MAC
    // PBKDF2 of Windows (CNG, bcrypt.dll): the same bytes as Rfc2898DeriveBytes, in a fraction of the time (the
    // managed HMAC of .NET Framework took 2.4 s for 600000 rounds at every opening of the vault)
    [System.Runtime.InteropServices.DllImport("bcrypt.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int BCryptOpenAlgorithmProvider(out IntPtr h, string alg, string impl, int flags);
    [System.Runtime.InteropServices.DllImport("bcrypt.dll")]
    static extern int BCryptDeriveKeyPBKDF2(IntPtr h, byte[] pwd, int cbPwd, byte[] salt, int cbSalt, ulong rounds, byte[] key, int cbKey, int flags);
    [System.Runtime.InteropServices.DllImport("bcrypt.dll")]
    static extern int BCryptCloseAlgorithmProvider(IntPtr h, int flags);
    static byte[] Pbkdf2(byte[] pwd, byte[] salt, int rounds) {
        IntPtr h; byte[] m = new byte[32];
        if (BCryptOpenAlgorithmProvider(out h, "SHA256", null, 8) == 0) {          // 8 = BCRYPT_ALG_HANDLE_HMAC_FLAG
            try { if (BCryptDeriveKeyPBKDF2(h, pwd, pwd.Length, salt, salt.Length, (ulong)rounds, m, 32, 0) == 0) return m; }
            finally { BCryptCloseAlgorithmProvider(h, 0); }
        }
        using (Rfc2898DeriveBytes k = new Rfc2898DeriveBytes(pwd, salt, rounds, HashAlgorithmName.SHA256)) return k.GetBytes(32);
    }
    static byte[] Keys(string code, byte[] salt, int rounds) {
        byte[] m = Pbkdf2(Encoding.UTF8.GetBytes(code), salt, rounds);
        using (HMACSHA256 h = new HMACSHA256(m)) return Cat(h.ComputeHash(Encoding.ASCII.GetBytes("otrvault1 aes")), h.ComputeHash(Encoding.ASCII.GetBytes("otrvault1 mac")));
    }
    static byte[] Mac(byte[] key, byte[] header, byte[] iv, byte[] data) {
        using (HMACSHA256 h = new HMACSHA256(key)) return h.ComputeHash(Cat(header, iv, data));
    }
    // "otrvault1:<rounds>:<salt>:<iv>:<data>:<mac>" (base64): the MAC covers the rounds, the salt, the IV and the data
    public static string Seal(string code, byte[] plain) {
        byte[] salt = new byte[16], iv = new byte[16];
        using (RandomNumberGenerator r = RandomNumberGenerator.Create()) { r.GetBytes(salt); r.GetBytes(iv); }
        byte[] k = Keys(code, salt, Rounds), ek = new byte[32], mk = new byte[32];
        Buffer.BlockCopy(k, 0, ek, 0, 32); Buffer.BlockCopy(k, 32, mk, 0, 32);
        byte[] data;
        using (Aes a = Aes.Create()) {
            a.Key = ek; a.IV = iv; a.Mode = CipherMode.CBC; a.Padding = PaddingMode.PKCS7;
            using (ICryptoTransform t = a.CreateEncryptor()) data = t.TransformFinalBlock(plain, 0, plain.Length);
        }
        byte[] header = Encoding.ASCII.GetBytes("otrvault1:" + Rounds + ":" + Convert.ToBase64String(salt));
        return "otrvault1:" + Rounds + ":" + Convert.ToBase64String(salt) + ":" + Convert.ToBase64String(iv) + ":" +
               Convert.ToBase64String(data) + ":" + Convert.ToBase64String(Mac(mk, header, iv, data));
    }
    // null = wrong code (or a changed file)
    public static byte[] Open(string code, string sealedText) {
        string[] f = sealedText.Trim().Split(':');
        if (f.Length != 6 || f[0] != "otrvault1") throw new FormatException("not a vault of this tool");
        int rounds = int.Parse(f[1]);
        if (rounds < 100000 || rounds > 10000000) throw new FormatException("vault rounds out of range");
        byte[] salt = Convert.FromBase64String(f[2]), iv = Convert.FromBase64String(f[3]);
        byte[] data = Convert.FromBase64String(f[4]), mac = Convert.FromBase64String(f[5]);
        byte[] k = Keys(code, salt, rounds), ek = new byte[32], mk = new byte[32];
        Buffer.BlockCopy(k, 0, ek, 0, 32); Buffer.BlockCopy(k, 32, mk, 0, 32);
        byte[] header = Encoding.ASCII.GetBytes("otrvault1:" + rounds + ":" + f[2]);
        if (!Same(Mac(mk, header, iv, data), mac)) return null;
        using (Aes a = Aes.Create()) {
            a.Key = ek; a.IV = iv; a.Mode = CipherMode.CBC; a.Padding = PaddingMode.PKCS7;
            using (ICryptoTransform t = a.CreateDecryptor()) return t.TransformFinalBlock(data, 0, data.Length);
        }
    }
}
