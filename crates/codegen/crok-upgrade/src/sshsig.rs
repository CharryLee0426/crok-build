//! Verification of OpenSSH `ssh-keygen -Y sign` signatures (the SSHSIG format) made with an
//! ed25519 key. Signing needs no tool beyond the ssh-keygen every Mac and Linux box ships:
//!
//! ```text
//! ssh-keygen -Y sign -f ~/.ssh/crok-release -n crok-release SHA256SUMS.txt
//! ```
//!
//! Format (PROTOCOL.sshsig in the OpenSSH sources): the armored blob is `SSHSIG`, a u32
//! version, then SSH strings for the public key, namespace, reserved, hash algorithm and the
//! signature. The signed data is `SSHSIG` followed by the namespace, reserved, hash algorithm
//! and the hash of the message, each as an SSH string.

use anyhow::{Context, Result, bail};
use base64::Engine;
use sha2::Digest;

const MAGIC: &[u8] = b"SSHSIG";
const VERSION: u32 = 1;
const KEY_TYPE: &str = "ssh-ed25519";

/// The ed25519 public keys a signature may come from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustedKeys {
    keys: Vec<[u8; 32]>,
}

impl TrustedKeys {
    /// Parses `ssh-ed25519 <base64> [comment]` lines, as `ssh-keygen` writes a `.pub` file.
    /// Blank lines and `#` comments are skipped.
    pub fn parse(text: &str) -> Result<Self> {
        let mut keys = Vec::new();
        for (index, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut fields = line.split_whitespace();
            let key_type = fields.next().unwrap_or_default();
            if key_type != KEY_TYPE {
                bail!(
                    "line {}: expected an {KEY_TYPE} key, found {key_type:?}",
                    index + 1
                );
            }
            let encoded = fields
                .next()
                .with_context(|| format!("line {}: missing key data", index + 1))?;
            let blob = base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .with_context(|| format!("line {}: key data is not base64", index + 1))?;
            keys.push(parse_public_key(&blob)?);
        }
        if keys.is_empty() {
            bail!("no trusted release keys");
        }
        Ok(Self { keys })
    }

    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// Checks that `armored` is a valid signature over `message`, made in `namespace` by one of
    /// the trusted keys.
    pub fn verify(&self, message: &[u8], armored: &str, namespace: &str) -> Result<()> {
        let blob = decode_armor(armored)?;
        let mut reader = Reader::new(&blob);
        if reader.take(MAGIC.len())? != MAGIC {
            bail!("not an SSH signature");
        }
        let version = reader.u32()?;
        if version != VERSION {
            bail!("unsupported SSH signature version {version}");
        }
        let signer = parse_public_key(reader.string()?)?;
        let signed_namespace = reader.string()?;
        if signed_namespace != namespace.as_bytes() {
            bail!(
                "signature namespace is {:?}, expected {namespace:?}",
                String::from_utf8_lossy(signed_namespace)
            );
        }
        let reserved = reader.string()?;
        let hash_algorithm = reader.string()?;
        let digest: Vec<u8> = match hash_algorithm {
            b"sha256" => sha2::Sha256::digest(message).to_vec(),
            b"sha512" => sha2::Sha512::digest(message).to_vec(),
            other => bail!(
                "unsupported signature hash {:?}",
                String::from_utf8_lossy(other)
            ),
        };
        let signature_blob = reader.string()?;
        let mut inner = Reader::new(signature_blob);
        if inner.string()? != KEY_TYPE.as_bytes() {
            bail!("the signature was not made with an {KEY_TYPE} key");
        }
        let signature = inner.string()?;

        let mut signed = Vec::with_capacity(MAGIC.len() + 4 * 4 + namespace.len() + 64);
        signed.extend_from_slice(MAGIC);
        put_string(&mut signed, namespace.as_bytes());
        put_string(&mut signed, reserved);
        put_string(&mut signed, hash_algorithm);
        put_string(&mut signed, &digest);

        if !self.keys.contains(&signer) {
            bail!("the signature was made with a key crok does not trust");
        }
        for key in &self.keys {
            let public = ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key);
            if public.verify(&signed, signature).is_ok() {
                return Ok(());
            }
        }
        bail!("the signature does not match the file")
    }
}

fn parse_public_key(blob: &[u8]) -> Result<[u8; 32]> {
    let mut reader = Reader::new(blob);
    let key_type = reader.string()?;
    if key_type != KEY_TYPE.as_bytes() {
        bail!(
            "expected an {KEY_TYPE} key, found {:?}",
            String::from_utf8_lossy(key_type)
        );
    }
    let key = reader.string()?;
    <[u8; 32]>::try_from(key).map_err(|_| anyhow::anyhow!("ed25519 key must be 32 bytes"))
}

fn decode_armor(text: &str) -> Result<Vec<u8>> {
    let mut lines = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty());
    if lines.next() != Some("-----BEGIN SSH SIGNATURE-----") {
        bail!("missing the SSH signature header");
    }
    let mut encoded = String::new();
    let mut closed = false;
    for line in lines {
        if line == "-----END SSH SIGNATURE-----" {
            closed = true;
            break;
        }
        encoded.push_str(line);
    }
    if !closed {
        bail!("missing the SSH signature footer");
    }
    base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .context("the SSH signature is not base64")
}

fn put_string(out: &mut Vec<u8>, value: &[u8]) {
    out.extend_from_slice(&(value.len() as u32).to_be_bytes());
    out.extend_from_slice(value);
}

struct Reader<'a> {
    data: &'a [u8],
    position: usize,
}

impl<'a> Reader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, position: 0 }
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8]> {
        let end = self
            .position
            .checked_add(length)
            .filter(|end| *end <= self.data.len())
            .context("truncated SSH signature")?;
        let slice = self
            .data
            .get(self.position..end)
            .context("truncated SSH signature")?;
        self.position = end;
        Ok(slice)
    }

    fn u32(&mut self) -> Result<u32> {
        let bytes = self.take(4)?;
        let array = <[u8; 4]>::try_from(bytes).context("truncated SSH signature")?;
        Ok(u32::from_be_bytes(array))
    }

    fn string(&mut self) -> Result<&'a [u8]> {
        let length = self.u32()? as usize;
        self.take(length)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Made with `ssh-keygen -t ed25519` and `ssh-keygen -Y sign -n crok-release` over MESSAGE.
    const PUBLIC: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHdYcXCAbHweL/4FvcVjZ7SI+3zHIKBw9MKltrZQn7Et crok release test\n";
    const MESSAGE: &[u8] = b"abc  file.dmg\n";
    const SIGNATURE: &str = "-----BEGIN SSH SIGNATURE-----
U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgd1hxcIBsfB4v/gW9xWNntIj7fM
cgoHD0wqW2tlCfsS0AAAAMY3Jvay1yZWxlYXNlAAAAAAAAAAZzaGE1MTIAAABTAAAAC3Nz
aC1lZDI1NTE5AAAAQKUN/JupMrWKcXejat8Yjsmri65W/q6I+90IAjP2v383z1bN+yuNdE
YYwiBSa9FEacYwZYexifjKy4X2Md7OywI=
-----END SSH SIGNATURE-----
";

    #[test]
    fn verifies_a_real_ssh_keygen_signature() {
        let keys = TrustedKeys::parse(PUBLIC).unwrap();
        assert_eq!(keys.len(), 1);
        keys.verify(MESSAGE, SIGNATURE, "crok-release").unwrap();
    }

    #[test]
    fn rejects_a_changed_message() {
        let keys = TrustedKeys::parse(PUBLIC).unwrap();
        let error = keys
            .verify(b"abd  file.dmg\n", SIGNATURE, "crok-release")
            .unwrap_err();
        assert!(error.to_string().contains("does not match"), "{error}");
    }

    #[test]
    fn rejects_another_namespace() {
        let keys = TrustedKeys::parse(PUBLIC).unwrap();
        let error = keys.verify(MESSAGE, SIGNATURE, "file").unwrap_err();
        assert!(error.to_string().contains("namespace"), "{error}");
    }

    #[test]
    fn rejects_an_untrusted_signer() {
        let other =
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n";
        let keys = TrustedKeys::parse(other).unwrap();
        let error = keys
            .verify(MESSAGE, SIGNATURE, "crok-release")
            .unwrap_err();
        assert!(error.to_string().contains("does not trust"), "{error}");
    }

    #[test]
    fn rejects_a_damaged_signature() {
        let keys = TrustedKeys::parse(PUBLIC).unwrap();
        let damaged = SIGNATURE.replace("QKUN", "QKUM");
        assert!(keys.verify(MESSAGE, &damaged, "crok-release").is_err());
        assert!(keys.verify(MESSAGE, "garbage", "crok-release").is_err());
    }

    #[test]
    fn key_file_parsing() {
        let text = format!("# comment\n\n{PUBLIC}{PUBLIC}");
        assert_eq!(TrustedKeys::parse(&text).unwrap().len(), 2);
        assert!(TrustedKeys::parse("ssh-rsa AAAA x\n").is_err());
        assert!(TrustedKeys::parse("\n").is_err());
    }
}
