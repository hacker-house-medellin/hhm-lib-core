export const serviceCatalog = Object.freeze({
  org: "hacker-house-medellin",
  title: "Hacker House Medellín",
  tagline: "A living operating system for technical coliving, coworking, and community build weeks in Medellín.",
  capabilities: ['intake', 'events', 'alerts', 'leads', 'status', 'analytics'],
  integrations: ["Stripe", "Google Calendar", "WhatsApp links", "Slack/Discord", "Door/access logs", "Maps"],
});

export function normalizeEmail(email) {
  if (typeof email !== 'string') return null;
  const value = email.trim().toLowerCase();
  return value.length <= 254 && !/[\u0000-\u001f\u007f]/u.test(value) && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value) ? value : null;
}

export function normalizeLeadName(name) {
  if (typeof name !== 'string' || /[\u0000-\u001f\u007f]/u.test(name)) return null;
  const value = name.trim().replace(/ {2,}/gu, ' ');
  return value.length >= 2 && value.length <= 120 ? value : null;
}

export function validateLead(input) {
  if (!input || typeof input !== 'object') return { ok: false, error: 'lead must be an object' };
  const email = normalizeEmail(input.email);
  if (!email) return { ok: false, error: 'valid email is required' };
  const name = normalizeLeadName(input.name);
  if (!name) return { ok: false, error: 'name must be between 2 and 120 characters without control characters' };
  return { ok: true, value: { ...input, email, name } };
}

export function makeEvent(type, payload = {}, meta = {}) {
  if (!/^[a-z][a-z0-9_.-]+$/.test(type)) throw new TypeError('event type must be a namespaced lowercase identifier');
  return { id: meta.id || crypto.randomUUID(), type, payload, product: serviceCatalog.org, occurredAt: meta.occurredAt || new Date().toISOString() };
}

export function classifyPriority(signal) {
  const severity = String(signal?.severity || '').toLowerCase();
  if (['critical', 'p0', 'sev0', 'sev1'].includes(severity)) return 'urgent';
  if (['high', 'p1', 'sev2'].includes(severity)) return 'high';
  if (['medium', 'p2', 'warn', 'warning'].includes(severity)) return 'normal';
  return 'low';
}
