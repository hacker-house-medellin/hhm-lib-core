import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeEmail, normalizeLeadName, validateLead } from '../src/index.mjs';

test('bounded lead names preserve readable Unicode and normalize spaces', () => {
  assert.equal(normalizeLeadName('  María   López  '), 'María López');
  assert.equal(normalizeLeadName(' X '), null);
  assert.equal(normalizeLeadName('X'.repeat(121)), null);
  for (const value of ['Line\nBreak', 'Tab\tName', 'Nul\0Byte']) {
    assert.equal(normalizeLeadName(value), null);
  }
});

test('lead payloads reject overlong fields and control chars', () => {
  for (const name of ['X'.repeat(121), 'New\nLine']) {
    assert.equal(validateLead({ name, email: 'reader@example.org' }).ok, false);
  }
  for (const email of ['a'.repeat(250)+'@example.org', 'a\0b@example.org']) {
    assert.equal(normalizeEmail(email), null);
    assert.equal(validateLead({ name: 'Reader', email }).ok, false);
  }
  assert.deepEqual(validateLead({ name: '  María   López ', email: ' MARIA@EXAMPLE.ORG ' }), {
    ok: true, value: { name: 'María López', email: 'maria@example.org' }
  });
});
