//! Fixed DSH Remote v1 Noise IK facade. No networking, storage, or provider calls.
mod resolver;

use snow::{Builder, HandshakeState, TransportState, params::DHChoice, resolvers::CryptoResolver};
use std::{fmt, sync::{Arc, Mutex, MutexGuard}};
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, Zeroizing};

const SUITE: &str = "Noise_IK_25519_ChaChaPoly_SHA256";
const MAX_MESSAGE: usize = 65_535;
const TAG: usize = 16;
const MAX_FIELD: usize = 1_024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum NoiseRole { Initiator, Responder }

/// Fixed, redacted errors; no payload, identity, key, or provider error is retained.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Error)]
pub enum NoiseError {
    InvalidKey,
    InvalidPrologue,
    InvalidState,
    MessageTooLarge,
    InvalidMessage,
    AuthenticationFailed,
    PeerIdentityMismatch,
    CounterExhausted,
    Closed,
    Unavailable,
}

impl fmt::Display for NoiseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InvalidKey => "Invalid Noise key.",
            Self::InvalidPrologue => "Invalid Noise context.",
            Self::InvalidState => "Noise operation is out of order.",
            Self::MessageTooLarge => "Noise message exceeds the supported limit.",
            Self::InvalidMessage => "Invalid Noise message.",
            Self::AuthenticationFailed => "Noise authentication failed.",
            Self::PeerIdentityMismatch => "Noise peer does not match enrollment.",
            Self::CounterExhausted => "Noise session counter is exhausted.",
            Self::Closed => "Noise session is closed.",
            Self::Unavailable => "Noise session is unavailable.",
        })
    }
}
impl std::error::Error for NoiseError {}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct NoiseCounters {
    pub complete: bool,
    pub sending: u64,
    pub receiving: u64,
}

#[derive(uniffi::Record)]
pub struct HandshakeRead {
    pub response: Option<Vec<u8>>,
    pub complete: bool,
}
impl fmt::Debug for HandshakeRead {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HandshakeRead").finish_non_exhaustive()
    }
}

struct HandshakePayload {
    payload: Vec<u8>,
    response: Option<Vec<u8>>,
    complete: bool,
}

/// Derive the enrollment public key using Snow's maintained X25519 provider.
/// The caller creates/stores the private input using its platform CSPRNG/vault.
#[uniffi::export]
pub fn derive_public_key(local_private_key: Vec<u8>) -> Result<Vec<u8>, NoiseError> {
    let key = Zeroizing::new(local_private_key);
    if key.len() != 32 { return Err(NoiseError::InvalidKey); }
    let mut dh = resolver::GuardedResolver.resolve_dh(&DHChoice::Curve25519).ok_or(NoiseError::Unavailable)?;
    dh.set(&key);
    Ok(dh.pubkey().to_vec())
}

struct Transport {
    noise: TransportState,
    sent: u64,
    received: u64,
}
enum Phase { Handshake(Box<HandshakeState>), Transport(Box<Transport>), Closed }
struct Inner {
    role: NoiseRole,
    peer: Zeroizing<Vec<u8>>,
    phase: Phase,
}
impl Inner {
    fn close(&mut self) {
        self.phase = Phase::Closed;
        self.peer.zeroize();
    }

    fn authenticate(&self, handshake: &HandshakeState) -> Result<(), NoiseError> {
        let actual = handshake.get_remote_static().ok_or(NoiseError::PeerIdentityMismatch)?;
        if bool::from(actual.ct_eq(self.peer.as_slice())) {
            Ok(())
        } else {
            Err(NoiseError::PeerIdentityMismatch)
        }
    }

    fn finalize(&mut self) -> Result<(), NoiseError> {
        let old = std::mem::replace(&mut self.phase, Phase::Closed);
        let Phase::Handshake(handshake) = old else { return Err(NoiseError::InvalidState); };
        self.authenticate(&handshake)?;
        let noise = (*handshake).into_transport_mode().map_err(|_| NoiseError::Unavailable)?;
        self.phase = Phase::Transport(Box::new(Transport { noise, sent: 0, received: 0 }));
        Ok(())
    }
}
impl Drop for Inner { fn drop(&mut self) { self.close(); } }

/// Each operation holds one mutex across state validation, crypto, and counter update.
/// Production entropy is always supplied by Snow's OS random provider.
#[derive(uniffi::Object)]
pub struct NoiseIkSession { inner: Mutex<Inner> }
impl fmt::Debug for NoiseIkSession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NoiseIkSession").finish_non_exhaustive()
    }
}

#[uniffi::export]
impl NoiseIkSession {
    #[uniffi::constructor]
    pub fn create(
        role: NoiseRole,
        local_private_key: Vec<u8>,
        enrolled_remote_public_key: Vec<u8>,
        connection_id: String,
        host_device_id: String,
        client_device_id: String,
    ) -> Result<Arc<Self>, NoiseError> {
        let key = Zeroizing::new(local_private_key);
        let peer = Zeroizing::new(enrolled_remote_public_key);
        let prologue = make_prologue(&connection_id, &host_device_id, &client_device_id)?;
        Self::build(role, &key, peer, &prologue).map(Arc::new)
    }

    /// DSH v1 handshake messages never carry application payloads.
    pub fn initiate(&self) -> Result<Vec<u8>, NoiseError> {
        self.initiate_internal(Vec::new())
    }

    /// A responder authenticates message 1 before emitting an empty message 2.
    /// Authenticated nonempty payloads are rejected before response/finalization.
    pub fn read_handshake(&self, message: Vec<u8>) -> Result<HandshakeRead, NoiseError> {
        let result = self.read_handshake_internal(message, Vec::new(), false)?;
        debug_assert!(result.payload.is_empty());
        Ok(HandshakeRead { response: result.response, complete: result.complete })
    }
}

impl NoiseIkSession {
    fn initiate_internal(&self, payload: Vec<u8>) -> Result<Vec<u8>, NoiseError> {
        let payload = Zeroizing::new(payload);
        let mut inner = self.lock()?;
        if inner.role != NoiseRole::Initiator { return Err(NoiseError::InvalidState); }
        let Phase::Handshake(handshake) = &mut inner.phase else { return Err(phase_error(&inner.phase)); };
        if !handshake.is_my_turn() { return Err(NoiseError::InvalidState); }
        if payload.len() > MAX_MESSAGE - 96 { return Err(NoiseError::MessageTooLarge); }
        let mut output = Zeroizing::new(vec![0_u8; payload.len() + 96]);
        match handshake.write_message(&payload, &mut output) {
            Ok(length) => Ok(output[..length].to_vec()),
            Err(_) => { inner.close(); Err(NoiseError::Unavailable) }
        }
    }

    // Only the cfg(test) fixture adapter supplies payloads/permits them. The FFI
    // always passes empty payloads and false, including in its own contract tests.
    fn read_handshake_internal(&self, message: Vec<u8>, response_payload: Vec<u8>, permit_fixture_payloads: bool) -> Result<HandshakePayload, NoiseError> {
        let response_payload = Zeroizing::new(response_payload);
        let mut inner = self.lock()?;
        let role = inner.role;
        let Phase::Handshake(handshake) = &mut inner.phase else { return Err(phase_error(&inner.phase)); };
        if handshake.is_my_turn() { return Err(NoiseError::InvalidState); }
        if (role == NoiseRole::Initiator && !response_payload.is_empty()) || response_payload.len() > MAX_MESSAGE - 48 {
            return Err(NoiseError::InvalidMessage);
        }
        let minimum = if role == NoiseRole::Responder { 96 } else { 48 };
        if message.len() < minimum || message.len() > MAX_MESSAGE {
            inner.close();
            return Err(NoiseError::InvalidMessage);
        }
        let mut payload = Zeroizing::new(vec![0_u8; message.len()]);
        let length = match handshake.read_message(&message, &mut payload) {
            Ok(length) => length,
            Err(_) => { inner.close(); return Err(NoiseError::AuthenticationFailed); }
        };
        // End the mutable handshake borrow before comparing against local enrollment.
        let authenticated = match &inner.phase {
            Phase::Handshake(h) => inner.authenticate(h),
            _ => Err(NoiseError::InvalidState),
        };
        if let Err(error) = authenticated { inner.close(); return Err(error); }
        if !permit_fixture_payloads && length != 0 { inner.close(); return Err(NoiseError::InvalidMessage); }
        let response = if role == NoiseRole::Responder {
            let mut output = Zeroizing::new(vec![0_u8; response_payload.len() + 48]);
            let Phase::Handshake(handshake) = &mut inner.phase else { unreachable!(); };
            match handshake.write_message(&response_payload, &mut output) {
                Ok(length) => Some(output[..length].to_vec()),
                Err(_) => { inner.close(); return Err(NoiseError::Unavailable); }
            }
        } else { None };
        if let Err(error) = inner.finalize() { inner.close(); return Err(error); }
        Ok(HandshakePayload { payload: payload[..length].to_vec(), response, complete: true })
    }
}

#[uniffi::export]
impl NoiseIkSession {
    pub fn encrypt(&self, plaintext: Vec<u8>) -> Result<Vec<u8>, NoiseError> {
        let plaintext = Zeroizing::new(plaintext);
        let mut inner = self.lock()?;
        let Phase::Transport(transport) = &mut inner.phase else { return Err(phase_error(&inner.phase)); };
        if plaintext.len() > MAX_MESSAGE - TAG { return Err(NoiseError::MessageTooLarge); }
        let Some(next) = transport.sent.checked_add(1) else { inner.close(); return Err(NoiseError::CounterExhausted); };
        if transport.noise.sending_nonce() != transport.sent { inner.close(); return Err(NoiseError::Unavailable); }
        let mut output = Zeroizing::new(vec![0_u8; plaintext.len() + TAG]);
        match transport.noise.write_message(&plaintext, &mut output) {
            Ok(length) => { transport.sent = next; Ok(output[..length].to_vec()) }
            Err(_) => { inner.close(); Err(NoiseError::Unavailable) }
        }
    }

    /// A rejected transport tag/replay does not advance the receiving nonce.
    /// The next valid in-order frame remains readable, matching the pinned DSH API.
    pub fn decrypt(&self, ciphertext: Vec<u8>) -> Result<Vec<u8>, NoiseError> {
        let mut inner = self.lock()?;
        let Phase::Transport(transport) = &mut inner.phase else { return Err(phase_error(&inner.phase)); };
        if ciphertext.len() < TAG { return Err(NoiseError::InvalidMessage); }
        if ciphertext.len() > MAX_MESSAGE { return Err(NoiseError::MessageTooLarge); }
        let Some(next) = transport.received.checked_add(1) else { inner.close(); return Err(NoiseError::CounterExhausted); };
        if transport.noise.receiving_nonce() != transport.received { inner.close(); return Err(NoiseError::Unavailable); }
        let mut output = Zeroizing::new(vec![0_u8; ciphertext.len() - TAG]);
        match transport.noise.read_message(&ciphertext, &mut output) {
            Ok(length) => { transport.received = next; Ok(output[..length].to_vec()) }
            Err(snow::Error::Decrypt) => {
                if transport.noise.receiving_nonce() != transport.received { inner.close(); return Err(NoiseError::Unavailable); }
                Err(NoiseError::AuthenticationFailed)
            }
            Err(_) => { inner.close(); Err(NoiseError::Unavailable) }
        }
    }

    pub fn counters(&self) -> Result<NoiseCounters, NoiseError> {
        let inner = self.lock()?;
        match &inner.phase {
            Phase::Handshake(_) => Ok(NoiseCounters { complete: false, sending: 0, receiving: 0 }),
            Phase::Transport(t) => Ok(NoiseCounters { complete: true, sending: t.sent, receiving: t.received }),
            Phase::Closed => Err(NoiseError::Closed),
        }
    }

    /// Close protocol state while retaining the language wrapper. Kotlin's
    /// generated AutoCloseable.close() separately releases its object handle.
    pub fn shutdown(&self) -> Result<(), NoiseError> { self.lock()?.close(); Ok(()) }
}

impl NoiseIkSession {
    fn lock(&self) -> Result<MutexGuard<'_, Inner>, NoiseError> {
        match self.inner.lock() {
            Ok(inner) => Ok(inner),
            Err(poisoned) => { poisoned.into_inner().close(); Err(NoiseError::Unavailable) }
        }
    }

    fn build(role: NoiseRole, key: &[u8], peer: Zeroizing<Vec<u8>>, prologue: &[u8]) -> Result<Self, NoiseError> {
        if key.len() != 32 || peer.len() != 32 || bool::from(peer.as_slice().ct_eq(&[0_u8; 32])) {
            return Err(NoiseError::InvalidKey);
        }
        let params = SUITE.parse().map_err(|_| NoiseError::Unavailable)?;
        let builder = Builder::with_resolver(params, Box::new(resolver::GuardedResolver))
            .local_private_key(key).map_err(|_| NoiseError::InvalidKey)?
            .prologue(prologue).map_err(|_| NoiseError::InvalidPrologue)?;
        Self::from_builder(role, peer, builder)
    }

    fn from_builder(role: NoiseRole, peer: Zeroizing<Vec<u8>>, builder: Builder<'_>) -> Result<Self, NoiseError> {
        let handshake = match role {
            NoiseRole::Initiator => builder.remote_public_key(&peer).map_err(|_| NoiseError::InvalidKey)?.build_initiator(),
            NoiseRole::Responder => builder.build_responder(),
        }.map_err(|_| NoiseError::Unavailable)?;
        Ok(Self { inner: Mutex::new(Inner { role, peer, phase: Phase::Handshake(Box::new(handshake)) }) })
    }
}

fn phase_error(phase: &Phase) -> NoiseError {
    if matches!(phase, Phase::Closed) { NoiseError::Closed } else { NoiseError::InvalidState }
}

fn make_prologue(connection: &str, host: &str, client: &str) -> Result<Zeroizing<Vec<u8>>, NoiseError> {
    if [connection, host, client].iter().any(|value| value.is_empty() || value.len() > MAX_FIELD || value.contains('\0')) {
        return Err(NoiseError::InvalidPrologue);
    }
    Ok(Zeroizing::new(format!("DSH-REMOTE\0v=1\0connection={connection}\0host={host}\0client={client}").into_bytes()))
}

uniffi::setup_scaffolding!();

#[cfg(test)]
mod tests;
