# PS Engagement — Ready-to-Send Email

Body stays short and scannable. The full deployment plan + architecture
goes as an attachment ([08-deployment-plan-and-architecture.md](08-deployment-plan-and-architecture.md),
exported to PDF before sending).

---

**To:** Rohan Shanbhag &lt;rohan.shanbhag@exotel.com&gt;
**Cc:** Shivakumar Ganesan &lt;shivku@exotel.com&gt;; Gaurav Agrawal &lt;gaurav.agrawal@exotel.com&gt;; Suraj Ghimire &lt;surajghimire@exotel.com&gt;; Sachin Bhatia &lt;sachin@exotel.com&gt;; Sahil Rajput &lt;sahil.rajput@exotel.com&gt;; Sahil Gandhi &lt;sahilgandhi@exotel.com&gt;; Ananda Kumar C &lt;anand@exotel.com&gt;
**Subject:** Re: Revenue system embedded in support — design + deployment plan

Hi Rohan, Shivku,

Picking up on the "revenue system embedded in support" thread — here's
where we landed after a design pass.

**What it does.** Every inbound support call and every new Salesforce
Case carries the account's revenue tier
(HYPERCARE / STRATEGIC / PREMIUM / STANDARD), so routing, priority, and
screen pop become tier-aware with no agent lookup. Tiers derive from
existing flags (`Hypercare_active__c`, `Top_Customer__c`,
`Is_SAAS_Premium_Account__c`, `SAAS_Enterprise_Account__c`, `RAG__c`) —
no new data entry.

**Status.** Salesforce side is built and sitting in the
`claude/upbeat-ride` branch — tier formulas, Before-Save Flow, queue
config (custom metadata), integration user + Connected App, Apex tests,
plus a stateless Node middleware for the IVR round-trip.

**What we need from PS** — the telephony + CTI wiring:

1. IVR nodeflow — HTTP action node into the router, branch on `queue_name`.
2. Four Exotel queue destinations bound to the Salesforce queues.
3. Open CTI softphone update for the tier banner + screen pop.
4. Three blocking capability questions (auth scheme, latency budget,
   `call_sid` pass-through).

**Ask.** 15-min sync to walk the design and sequence the next steps.
Suggested (IST) — grab whichever works, happy to flex:

- `<Tue DD-MMM>` 3:30 pm
- `<Wed DD-MMM>` 11:00 am
- `<Thu DD-MMM>` 4:00 pm

Full deployment plan, architecture, dependency matrix, and rollout
guardrails attached.

Thanks,
Shivanand

---

## Attachment to include

- `08-deployment-plan-and-architecture.pdf` — exported from
  [08-deployment-plan-and-architecture.md](08-deployment-plan-and-architecture.md)

## Optional follow-up (after first reply)

> Thanks for the feedback. To unblock UAT we need:
> - [ ] Confirmation of the Exotel HTTP action node auth scheme (header pass-through vs. token in body).
> - [ ] Two test numbers we can dial into a staging IVR to verify the routing branch.
> - [ ] Telephony-side lead time for the four queue destinations, so we can sequence the Salesforce deploy.
>
> Once we have those, we can pencil in a UAT window for the following week.
