//! Policy around Snow's maintained primitives; no cipher, hash, or DH implementation.
use snow::{
    params::{CipherChoice, DHChoice, HashChoice},
    resolvers::{CryptoResolver, DefaultResolver},
    types::{Cipher, Dh, Hash, Random},
};
use subtle::ConstantTimeEq;
use zeroize::Zeroize;

pub(crate) struct GuardedResolver;

impl CryptoResolver for GuardedResolver {
    fn resolve_rng(&self) -> Option<Box<dyn Random>> {
        DefaultResolver.resolve_rng()
    }

    fn resolve_dh(&self, choice: &DHChoice) -> Option<Box<dyn Dh>> {
        DefaultResolver.resolve_dh(choice).map(|inner| Box::new(ContributoryDh(inner)) as Box<dyn Dh>)
    }

    fn resolve_hash(&self, choice: &HashChoice) -> Option<Box<dyn Hash>> {
        DefaultResolver.resolve_hash(choice)
    }

    fn resolve_cipher(&self, choice: &CipherChoice) -> Option<Box<dyn Cipher>> {
        DefaultResolver.resolve_cipher(choice)
    }
}

struct ContributoryDh(Box<dyn Dh>);

impl Dh for ContributoryDh {
    fn name(&self) -> &'static str { self.0.name() }
    fn pub_len(&self) -> usize { self.0.pub_len() }
    fn priv_len(&self) -> usize { self.0.priv_len() }
    fn dh_len(&self) -> usize { self.0.dh_len() }
    fn set(&mut self, key: &[u8]) { self.0.set(key); }
    fn generate(&mut self, rng: &mut dyn Random) -> Result<(), snow::Error> { self.0.generate(rng) }
    fn pubkey(&self) -> &[u8] { self.0.pubkey() }
    fn privkey(&self) -> &[u8] { self.0.privkey() }

    fn dh(&self, public: &[u8], out: &mut [u8]) -> Result<(), snow::Error> {
        self.0.dh(public, out)?;
        // Snow 0.10's default X25519 provider permits a non-contributory result.
        // A malformed or low-order peer must never establish a transport session.
        if bool::from(out[..self.dh_len()].ct_eq(&[0_u8; 32])) {
            out.zeroize();
            return Err(snow::Error::Dh);
        }
        Ok(())
    }
}
