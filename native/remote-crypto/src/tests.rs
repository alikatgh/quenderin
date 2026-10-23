use super::*;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::Value;
use sha1::{Digest, Sha1};

// The public DSH carrier uses empty payloads. Its upstream generic Noise golden
// fixture intentionally carries synthetic payloads, so only this test adapter
// can exercise those exact bytes without exposing payload controls through FFI.
impl NoiseIkSession {
    fn initiate_fixture(&self, payload: Vec<u8>) -> Result<Vec<u8>, NoiseError> {
        self.initiate_internal(payload)
    }
    fn read_handshake_fixture(&self, message: Vec<u8>, response: Vec<u8>) -> Result<HandshakePayload, NoiseError> {
        self.read_handshake_internal(message, response, true)
    }
}

// The fixture is public synthetic upstream test data, fetched only by the bounded
// CI verifier. It is deliberately not copied into this repository while its
// repository-wide redistribution license remains unresolved.
fn fixture() -> Value {
    let path = std::env::var_os("DSH_NOISE_VECTOR_PATH").expect("pinned external fixture path is required");
    let bytes = std::fs::read(path).expect("pinned external fixture is required");
    assert!(bytes.len() == 2_960, "unexpected pinned fixture length");
    let mut blob = Sha1::new();
    blob.update(format!("blob {}\0", bytes.len()).as_bytes());
    blob.update(&bytes);
    assert!(format!("{:x}", blob.finalize()) == "52e83a5de8444dbd13115ccd3d8131950907e302", "pinned synthetic fixture provenance differs");
    let value: Value = serde_json::from_slice(&bytes).expect("invalid synthetic fixture JSON");
    assert!(value["fixtureFormat"] == "dsh-remote.noise-vectors");
    assert!(value["fixtureFormatVersion"] == 1 && value["protocolVersion"] == 1);
    assert!(value["suite"] == SUITE && value["encoding"] == "base64url-no-padding");
    assert!(!value["vectors"].as_array().expect("missing vectors").is_empty());
    value
}

fn bytes(value: &Value) -> Vec<u8> {
    URL_SAFE_NO_PAD.decode(value.as_str().expect("fixture field must be text")).expect("invalid synthetic fixture encoding")
}
fn text(value: &Value) -> &str { value.as_str().expect("missing fixture field") }
fn peer_role(role: NoiseRole) -> &'static str {
    match role { NoiseRole::Initiator => "responder", NoiseRole::Responder => "initiator" }
}
fn local_role(role: NoiseRole) -> &'static str { peer_role(if role == NoiseRole::Initiator { NoiseRole::Responder } else { NoiseRole::Initiator }) }

fn session(vector: &Value, role: NoiseRole) -> NoiseIkSession {
    let key = Zeroizing::new(bytes(&vector["staticKeys"][local_role(role)]["privateKey"]));
    let peer = Zeroizing::new(bytes(&vector["staticKeys"][peer_role(role)]["publicKey"]));
    let ephemeral = Zeroizing::new(bytes(&vector["ephemeralPrivateKeys"][local_role(role)]));
    assert!(key.len() == 32 && peer.len() == 32 && ephemeral.len() == 32, "invalid fixture key length");
    let prologue = make_prologue(text(&vector["prologue"]["connectionId"]), text(&vector["prologue"]["hostDeviceId"]), text(&vector["prologue"]["clientDeviceId"])).unwrap();
    let builder = Builder::with_resolver(SUITE.parse().unwrap(), Box::new(resolver::GuardedResolver))
        .local_private_key(&key).unwrap().prologue(&prologue).unwrap()
        .fixed_ephemeral_key_for_testing_only(&ephemeral);
    NoiseIkSession::from_builder(role, peer, builder).unwrap()
}

fn pair(vector: &Value) -> (NoiseIkSession, NoiseIkSession) {
    let initiator = session(vector, NoiseRole::Initiator);
    let responder = session(vector, NoiseRole::Responder);
    let first = initiator.initiate_fixture(bytes(&vector["handshake"]["message1"]["payload"])).unwrap();
    let reply = responder.read_handshake_fixture(first, bytes(&vector["handshake"]["message2"]["payload"])).unwrap();
    initiator.read_handshake_fixture(reply.response.unwrap(), vec![]).unwrap();
    (initiator, responder)
}

fn counters(initiator: &NoiseIkSession, responder: &NoiseIkSession, expected: &Value) {
    let a = initiator.counters().unwrap();
    let b = responder.counters().unwrap();
    assert!(a.complete && b.complete);
    for (name, actual) in [("initiatorSending", a.sending), ("initiatorReceiving", a.receiving), ("responderSending", b.sending), ("responderReceiving", b.receiving)] {
        assert!(actual.to_string() == text(&expected[name]), "fixture counter differs");
    }
}

#[test]
fn dsh_golden_both_roles_handshake_ciphertexts_and_counters() {
    let file = fixture();
    for vector in file["vectors"].as_array().unwrap() {
        let prologue = make_prologue(text(&vector["prologue"]["connectionId"]), text(&vector["prologue"]["hostDeviceId"]), text(&vector["prologue"]["clientDeviceId"])).unwrap();
        assert!(prologue.as_slice() == bytes(&vector["prologue"]["bytes"]), "fixture prologue differs");
        for role in ["initiator", "responder"] {
            let key = Zeroizing::new(bytes(&vector["staticKeys"][role]["privateKey"]));
            let public = derive_public_key(key.to_vec()).unwrap();
            assert!(bool::from(public.ct_eq(&bytes(&vector["staticKeys"][role]["publicKey"]))), "fixture static public key differs");
        }
        let initiator = session(vector, NoiseRole::Initiator);
        let responder = session(vector, NoiseRole::Responder);
        let first = initiator.initiate_fixture(bytes(&vector["handshake"]["message1"]["payload"])).unwrap();
        assert!(first == bytes(&vector["handshake"]["message1"]["message"]), "fixture message 1 differs");
        let second = responder.read_handshake_fixture(first, bytes(&vector["handshake"]["message2"]["payload"])).unwrap();
        assert!(second.payload == bytes(&vector["handshake"]["message1"]["payload"]), "message 1 payload differs");
        let response = second.response.unwrap();
        assert!(response == bytes(&vector["handshake"]["message2"]["message"]), "fixture message 2 differs");
        let finished = initiator.read_handshake_fixture(response, vec![]).unwrap();
        assert!(finished.payload == bytes(&vector["handshake"]["message2"]["payload"]) && finished.response.is_none(), "message 2 payload differs");
        counters(&initiator, &responder, &vector["countersAfterHandshake"]);
        for transport in vector["transport"].as_array().unwrap() {
            let (source, target) = if transport["sender"] == "initiator" { (&initiator, &responder) } else { (&responder, &initiator) };
            let plaintext = bytes(&transport["plaintext"]);
            let ciphertext = source.encrypt(plaintext.clone()).unwrap();
            assert!(ciphertext == bytes(&transport["ciphertext"]), "fixture transport ciphertext differs");
            assert!(target.decrypt(ciphertext).unwrap() == plaintext, "fixture transport plaintext differs");
            counters(&initiator, &responder, &transport["countersAfter"]);
        }
    }
}

#[test]
fn public_api_requires_empty_handshakes_and_derives_only_public_keys() {
    for length in [0, 31, 33] {
        assert!(matches!(derive_public_key(vec![0; length]), Err(NoiseError::InvalidKey)));
    }
    assert!(derive_public_key(vec![0x42; 32]).unwrap().len() == 32);
    let file = fixture(); let vector = &file["vectors"][0];
    let create = |role| NoiseIkSession::create(
        role,
        bytes(&vector["staticKeys"][local_role(role)]["privateKey"]),
        bytes(&vector["staticKeys"][peer_role(role)]["publicKey"]),
        text(&vector["prologue"]["connectionId"]).to_owned(),
        text(&vector["prologue"]["hostDeviceId"]).to_owned(),
        text(&vector["prologue"]["clientDeviceId"]).to_owned(),
    ).unwrap();
    let initiator = create(NoiseRole::Initiator);
    let responder = create(NoiseRole::Responder);
    let first = initiator.initiate().unwrap();
    assert!(first.len() == 96);
    let second = responder.read_handshake(first).unwrap();
    assert!(second.complete && second.response.as_ref().unwrap().len() == 48);
    assert!(initiator.read_handshake(second.response.unwrap()).unwrap().complete);
    let initiator = session(vector, NoiseRole::Initiator);
    let responder = session(vector, NoiseRole::Responder);
    let with_payload = initiator.initiate_fixture(b"reject before response".to_vec()).unwrap();
    assert!(matches!(responder.read_handshake(with_payload), Err(NoiseError::InvalidMessage)));
    assert!(matches!(responder.counters(), Err(NoiseError::Closed)));

    let initiator = session(vector, NoiseRole::Initiator);
    let responder = session(vector, NoiseRole::Responder);
    let first = initiator.initiate().unwrap();
    let with_payload = responder.read_handshake_fixture(first, b"reject final payload".to_vec()).unwrap().response.unwrap();
    assert!(matches!(initiator.read_handshake(with_payload), Err(NoiseError::InvalidMessage)));
    assert!(matches!(initiator.counters(), Err(NoiseError::Closed)));
}

#[test]
fn enrolled_peer_mismatch_closes_before_payload_or_response() {
    let file = fixture(); let vector = &file["vectors"][0];
    let initiator = session(vector, NoiseRole::Initiator);
    let responder = session(vector, NoiseRole::Responder);
    responder.inner.lock().unwrap().peer[0] ^= 1;
    let first = initiator.initiate_fixture(vec![]).unwrap();
    assert!(matches!(responder.read_handshake_fixture(first, vec![]), Err(NoiseError::PeerIdentityMismatch)));
    assert_eq!(responder.counters(), Err(NoiseError::Closed));
    assert_eq!(responder.encrypt(vec![]), Err(NoiseError::Closed));
}

#[test]
fn wrong_context_and_handshake_tampering_close_both_roles() {
    let file = fixture(); let vector = &file["vectors"][0];
    for tamper_at in [0_usize, 40, 95] {
        let initiator = session(vector, NoiseRole::Initiator);
        let responder = session(vector, NoiseRole::Responder);
        let mut first = initiator.initiate_fixture(vec![]).unwrap();
        first[tamper_at] ^= 1;
        assert!(responder.read_handshake_fixture(first, vec![]).is_err());
        assert_eq!(responder.counters(), Err(NoiseError::Closed));
    }
    let initiator = session(vector, NoiseRole::Initiator);
    let responder = session(vector, NoiseRole::Responder);
    let first = initiator.initiate_fixture(vec![]).unwrap();
    let mut second = responder.read_handshake_fixture(first, vec![]).unwrap().response.unwrap();
    second[47] ^= 1;
    assert!(initiator.read_handshake_fixture(second, vec![]).is_err());
    assert_eq!(initiator.counters(), Err(NoiseError::Closed));

    let key = Zeroizing::new(bytes(&vector["staticKeys"]["responder"]["privateKey"]));
    let connection = text(&vector["prologue"]["connectionId"]);
    let host = text(&vector["prologue"]["hostDeviceId"]);
    let client = text(&vector["prologue"]["clientDeviceId"]);
    for prologue in [make_prologue("other", host, client).unwrap(), make_prologue(connection, "other", client).unwrap(), make_prologue(connection, host, "other").unwrap()] {
        let initiator = session(vector, NoiseRole::Initiator);
        let responder = NoiseIkSession::build(NoiseRole::Responder, &key, Zeroizing::new(bytes(&vector["staticKeys"]["initiator"]["publicKey"])), &prologue).unwrap();
        assert!(responder.read_handshake_fixture(initiator.initiate_fixture(vec![]).unwrap(), vec![]).is_err());
        assert_eq!(responder.counters(), Err(NoiseError::Closed));
    }
}

#[test]
fn tamper_and_replay_do_not_advance_nonce_and_next_valid_frame_works() {
    let file = fixture(); let (initiator, responder) = pair(&file["vectors"][0]);
    let first = initiator.encrypt(b"first".to_vec()).unwrap();
    let mut tampered = first.clone(); tampered[0] ^= 1;
    assert_eq!(responder.decrypt(tampered), Err(NoiseError::AuthenticationFailed));
    assert_eq!(responder.counters().unwrap().receiving, 0);
    assert!(responder.decrypt(first.clone()).unwrap() == b"first");
    assert_eq!(responder.decrypt(first), Err(NoiseError::AuthenticationFailed));
    assert_eq!(responder.counters().unwrap().receiving, 1);
    assert!(responder.decrypt(initiator.encrypt(b"next".to_vec()).unwrap()).unwrap() == b"next");
    assert_eq!(responder.counters().unwrap().receiving, 2);
}

#[test]
fn rejects_invalid_context_keys_order_and_message_bounds() {
    for invalid in ["", "bad\0field"] {
        assert!(make_prologue(invalid, "host", "client").is_err());
        assert!(make_prologue("connection", invalid, "client").is_err());
        assert!(make_prologue("connection", "host", invalid).is_err());
    }
    assert!(make_prologue(&"a".repeat(MAX_FIELD + 1), "host", "client").is_err());
    assert!(make_prologue("a=\u{1f9dd}", "\u{4e3b}\u{673a}", "client").is_ok());
    assert!(NoiseIkSession::build(NoiseRole::Initiator, &[1_u8; 31], Zeroizing::new(vec![1; 32]), b"context").is_err());
    assert!(NoiseIkSession::build(NoiseRole::Initiator, &[1_u8; 32], Zeroizing::new(vec![0; 32]), b"context").is_err());
    let file = fixture(); let vector = &file["vectors"][0];
    let initiator = session(vector, NoiseRole::Initiator); let responder = session(vector, NoiseRole::Responder);
    assert!(matches!(initiator.read_handshake_fixture(vec![], vec![]), Err(NoiseError::InvalidState)));
    assert_eq!(responder.initiate_fixture(vec![]), Err(NoiseError::InvalidState));
    assert_eq!(initiator.encrypt(vec![]), Err(NoiseError::InvalidState));
    assert_eq!(initiator.initiate_fixture(vec![0; MAX_MESSAGE - 95]), Err(NoiseError::MessageTooLarge));
    assert!(!initiator.counters().unwrap().complete);
    let (initiator, responder) = pair(vector);
    assert_eq!(initiator.encrypt(vec![0; MAX_MESSAGE - TAG + 1]), Err(NoiseError::MessageTooLarge));
    assert_eq!(responder.decrypt(vec![0; MAX_MESSAGE + 1]), Err(NoiseError::MessageTooLarge));
    assert_eq!(responder.decrypt(vec![0; TAG - 1]), Err(NoiseError::InvalidMessage));
    let max = vec![0x5a; MAX_MESSAGE - TAG];
    let encrypted = initiator.encrypt(max.clone()).unwrap();
    assert!(encrypted.len() == MAX_MESSAGE && responder.decrypt(encrypted).unwrap() == max);
    initiator.close().unwrap(); initiator.close().unwrap();
    assert_eq!(initiator.encrypt(vec![]), Err(NoiseError::Closed));
}

#[test]
fn rejects_low_order_dh_and_counter_exhaustion_without_nonce_reuse() {
    let mut dh = resolver::GuardedResolver.resolve_dh(&DHChoice::Curve25519).unwrap();
    dh.set(&[0x42; 32]);
    for public in [vec![0; 32], { let mut one = vec![0; 32]; one[0] = 1; one }] {
        let mut out = [0x55; 32];
        assert!(dh.dh(&public, &mut out).is_err());
        assert!(out == [0; 32], "rejected shared output was not cleared");
    }
    let file = fixture();
    for sending in [true, false] {
        let (initiator, _) = pair(&file["vectors"][0]);
        if let Phase::Transport(t) = &mut initiator.inner.lock().unwrap().phase {
            if sending { t.sent = u64::MAX; } else { t.received = u64::MAX; }
        }
        let result = if sending { initiator.encrypt(vec![]) } else { initiator.decrypt(vec![0; TAG]) };
        assert_eq!(result, Err(NoiseError::CounterExhausted));
        assert_eq!(initiator.counters(), Err(NoiseError::Closed));
    }
}

#[test]
fn concurrent_encrypt_serializes_nonce_allocation() {
    let file = fixture(); let (initiator, responder) = pair(&file["vectors"][0]);
    let initiator = Arc::new(initiator);
    let mut workers = vec![];
    for _ in 0..8 {
        let session = Arc::clone(&initiator);
        workers.push(std::thread::spawn(move || session.encrypt(b"same".to_vec()).unwrap()));
    }
    let mut messages = workers.into_iter().map(|w| w.join().unwrap()).collect::<Vec<_>>();
    let mut unique = messages.clone(); unique.sort(); unique.dedup();
    assert!(unique.len() == 8, "concurrent send reused a nonce");
    for _ in 0..8 {
        let next = messages.iter().position(|m| responder.decrypt(m.clone()).is_ok()).expect("missing next in-order ciphertext");
        messages.remove(next);
    }
    assert!(initiator.counters().unwrap().sending == 8 && responder.counters().unwrap().receiving == 8);
}

#[test]
fn poisoned_lock_erases_facade_state_and_refuses_further_operations() {
    let file = fixture(); let (initiator, _) = pair(&file["vectors"][0]);
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _locked = initiator.inner.lock().unwrap();
        panic!("synthetic lock poison");
    }));
    assert!(matches!(initiator.encrypt(vec![]), Err(NoiseError::Unavailable)));
    assert!(matches!(initiator.counters(), Err(NoiseError::Unavailable)));
    let inner = match initiator.inner.lock() {
        Err(poisoned) => poisoned.into_inner(),
        Ok(_) => panic!("expected synthetic lock poison"),
    };
    assert!(matches!(&inner.phase, Phase::Closed) && inner.peer.iter().all(|byte| *byte == 0));
}
