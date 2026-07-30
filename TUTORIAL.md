# How to Put an AWS Load Balancer (ALB) in Front of a Keycloak Server on EC2

**A beginner tutorial. No experience needed.**

Last updated: July 2026 · Uses Keycloak **26.7** (the current release) and the current AWS console.

---

## Table of Contents

1. [What you are going to build](#1-what-you-are-going-to-build)
2. [The picture (read this first)](#2-the-picture-read-this-first)
3. [Mini dictionary of scary words](#3-mini-dictionary-of-scary-words)
4. [PART 1 — The step-by-step build](#4-part-1--the-step-by-step-build)
5. [PART 2 — Background: what each piece really is](#5-part-2--background-what-each-piece-really-is)
6. [PART 3 — "What does an ALB need to be reachable at a host name?"](#6-part-3--what-does-an-alb-need-to-be-reachable-at-a-host-name)
7. [PART 4 — The full journey of one request](#7-part-4--the-full-journey-of-one-request)
8. [PART 5 — Best practices (2026)](#8-part-5--best-practices-2026)
9. [PART 6 — Your choices, with pros and cons](#9-part-6--your-choices-with-pros-and-cons)
10. [PART 7 — Troubleshooting: what broke and why](#10-part-7--troubleshooting-what-broke-and-why)
11. [PART 8 — The same thing with copy-paste CLI commands](#11-part-8--the-same-thing-with-copy-paste-cli-commands)
12. [PART 9 — What this costs](#12-part-9--what-this-costs)
13. [PART 10 — One-page cheat sheet](#13-part-10--one-page-cheat-sheet)
14. [Where to read more](#14-where-to-read-more)

---

## 1. What you are going to build

You want people to type **`https://login.example.com`** into a browser and land on a **Keycloak** login page that is running on an **EC2 server** inside Amazon's cloud.

Right now, without any of this, your Keycloak server is like a house with no street address and no front door. It exists, but nobody can find it, and if they did find it, anyone could walk in.

We are going to add three things:

1. **A street address** — a real domain name that points at Amazon.
2. **A front desk** — an Application Load Balancer (ALB) that greets every visitor.
3. **A locked back hallway** — security rules so the only way to reach Keycloak is *through* the front desk.

By the end you will have a working, encrypted (`https://`) login page.

**Time needed:** about 60–90 minutes the first time.

---

## 2. The picture (read this first)

Everything in this tutorial is just these boxes talking to each other. Come back to this picture whenever you get lost.

```
        You, in a browser
        https://login.example.com
                 |
                 |  (1) "What IP address is login.example.com?"
                 v
        +---------------------+
        |   DNS / Route 53    |   "It's over there ->"
        +---------------------+
                 |
                 |  (2) encrypted HTTPS traffic on port 443
                 v
   ============================================
   |   APPLICATION LOAD BALANCER (the ALB)    |   <- lives in 2+ Availability Zones
   |                                          |
   |   Listener  :443 HTTPS  (holds the       |
   |             certificate for              |
   |             login.example.com)           |
   |   Listener  :80  HTTP   (just redirects  |
   |             everyone to 443)             |
   ============================================
                 |
                 |  (3) plain HTTP on port 8080, inside your private network
                 |      plus extra "X-Forwarded-*" notes attached
                 v
        +---------------------+
        |    TARGET GROUP     |   <- the list of servers, and the
        |  (health-checked)   |      health checker that pokes them
        +---------------------+
                 |
                 v
        +---------------------+
        |  EC2 instance       |
        |  Keycloak 26.7      |
        |  listening on 8080  |
        +---------------------+
                 |
                 v
        +---------------------+
        |  RDS PostgreSQL     |   <- where users & passwords are stored
        +---------------------+
```

The single most important idea: **the ALB is a middleman.** The browser never talks to Keycloak directly. It talks to the ALB, and the ALB talks to Keycloak on its behalf.

---

## 3. Mini dictionary of scary words

Read these once. You do not have to memorize them — just know they exist.

| Word | What it actually means |
|---|---|
| **EC2 instance** | A rented computer in Amazon's data center. It has an operating system, like your laptop does. |
| **Keycloak** | Free software that handles logins. It stores usernames, checks passwords, and hands out "you're logged in" tickets to other apps. |
| **VPC** | Your own private network inside AWS. Like your own fenced-off neighborhood. |
| **Subnet** | A smaller street inside that neighborhood. *Public* subnets can reach the internet; *private* ones cannot. |
| **Availability Zone (AZ)** | A separate building/data center. AWS makes you use two so that if one building loses power, you're still up. |
| **Load balancer** | A traffic cop that receives requests and hands them to servers. |
| **ALB** | "Application Load Balancer" — the kind of load balancer that understands web traffic (URLs, host names, cookies). |
| **Listener** | The ALB's ear. It says "I listen on port 443 for HTTPS." |
| **Rule** | An if/then instruction on a listener: *if* the host name is X, *then* send it to target group Y. |
| **Target group** | A named list of servers plus the health test used on them. |
| **Target** | One server in that list. |
| **Health check** | The ALB poking a server every few seconds asking "you alive?" |
| **Security group** | A firewall. It's a list of "who is allowed to knock on which door." |
| **Port** | A numbered door on a computer. Web = 80, secure web = 443, Keycloak's default = 8080. |
| **TLS / SSL** | The encryption that turns `http://` into `https://`. Scrambles traffic so nobody can read it in transit. |
| **Certificate** | A digital ID card proving "I really am login.example.com." |
| **ACM** | AWS Certificate Manager — where you get free certificates. |
| **DNS** | The internet's phone book. Turns names into addresses. |
| **Route 53** | AWS's DNS service. |
| **Host header** | A line inside every web request that says which name the browser typed. |
| **Reverse proxy** | A general name for "middleman in front of a server." An ALB is a reverse proxy. |

---

## 4. PART 1 — The step-by-step build

> **The rule of this section:** do the steps in order. Each step depends on the one before it. Don't skip ahead, even if you think you know.

### Step 0 — Check you have these things

Before you start, you need:

- [ ] An AWS account you can log into.
- [ ] A **VPC** with **at least two public subnets in two different Availability Zones**. (The default VPC that comes with every AWS account already has this. You can use it.)
- [ ] An **EC2 instance** already running, in that VPC. `t3.medium` or bigger — Keycloak is a Java app and 1 GB of RAM is not enough.
- [ ] A **domain name** you control (like `example.com`), ideally with its DNS hosted in **Route 53**.
- [ ] Permission in AWS to create load balancers, target groups, security groups, and certificates.

**Naming plan for this tutorial** (change these to your real values as you go):

| Thing | Value we'll use |
|---|---|
| Public URL | `https://login.example.com` |
| EC2 instance | `i-0abc123keycloak` |
| Keycloak port | `8080` |
| Keycloak health port | `9000` |
| ALB name | `keycloak-alb` |
| Target group name | `keycloak-tg` |
| ALB security group | `sg-alb-keycloak` |
| EC2 security group | `sg-ec2-keycloak` |

---

### Step 1 — Get a free TLS certificate

The ALB cannot serve `https://` without an ID card. That ID card is the certificate.

1. Go to the AWS console → search for **Certificate Manager (ACM)**.
2. **Important:** make sure the region selector (top right) shows the **same region as your EC2 instance**. A certificate in the wrong region is invisible to your ALB.
3. Click **Request** → **Request a public certificate** → **Next**.
4. In *Fully qualified domain name*, type `login.example.com`.
   - *Optional but smart:* click **Add another name** and add `*.example.com` if you'll want more subdomains later.
5. Validation method: choose **DNS validation** (easier and it auto-renews forever).
6. Click **Request**.
7. Open the new certificate. It says **Pending validation**. You must prove you own the domain.
   - If your domain is in Route 53: click **Create records in Route 53**. Done. AWS adds the proof record for you.
   - If it's somewhere else (GoDaddy, Cloudflare, Namecheap): copy the CNAME name and value shown, and paste them into your DNS provider's control panel.
8. Wait 5–30 minutes. Refresh until status = **Issued**. ✅

> **Why free?** ACM public certificates cost $0 and renew themselves automatically, as long as the DNS validation record stays in place. This is one of the genuinely great deals in AWS. Never delete that validation record.

---

### Step 2 — Create two security groups

Security groups are firewalls. We need two, and the second one points at the first. This is the trick that makes the whole thing secure.

#### 2a. The ALB's security group (`sg-alb-keycloak`)

EC2 console → **Security Groups** → **Create security group**.

- Name: `sg-alb-keycloak`
- Description: `Allows public web traffic into the Keycloak ALB`
- VPC: your VPC

**Inbound rules:**

| Type | Protocol | Port | Source | Why |
|---|---|---|---|---|
| HTTPS | TCP | 443 | `0.0.0.0/0` | Let the whole internet reach the login page securely |
| HTTP | TCP | 80 | `0.0.0.0/0` | So we can catch people who typed `http://` and bounce them to `https://` |

**Outbound rules:** leave the default (all traffic allowed out).

Save it. Note the ID, e.g. `sg-01111aaa`.

#### 2b. The EC2 instance's security group (`sg-ec2-keycloak`)

Create a second one:

- Name: `sg-ec2-keycloak`
- VPC: same VPC

**Inbound rules:**

| Type | Protocol | Port | Source | Why |
|---|---|---|---|---|
| Custom TCP | TCP | 8080 | **`sg-alb-keycloak`** | Only the ALB may talk to Keycloak |
| Custom TCP | TCP | 9000 | **`sg-alb-keycloak`** | Only the ALB may run health checks |
| SSH | TCP | 22 | *your* IP only, e.g. `203.0.113.45/32` | So you can log in and fix things |

> 🔑 **This is the most important idea in the whole tutorial.** In the *Source* box, instead of typing an IP address, you type the **other security group's ID**. That tells AWS: "the only computers allowed through this door are ones wearing the ALB's badge."
>
> This is why nobody on the internet can skip the ALB and hit your Keycloak directly. Even if they somehow learn the EC2 server's IP address, the door won't open for them.

Now attach `sg-ec2-keycloak` to your EC2 instance:
EC2 → Instances → select it → **Actions → Security → Change security groups** → pick `sg-ec2-keycloak` → **Save**.

---

### Step 3 — Configure Keycloak on the EC2 instance

SSH into the box. If you haven't installed Keycloak yet, here is the short version for Amazon Linux 2023.

```bash
# Keycloak 26.x needs Java 21
sudo dnf install -y java-21-amazon-corretto-headless

# Download and unpack Keycloak (check keycloak.org/downloads for the newest number)
cd /opt
sudo curl -LO https://github.com/keycloak/keycloak/releases/download/26.7.0/keycloak-26.7.0.tar.gz
sudo tar -xzf keycloak-26.7.0.tar.gz
sudo mv keycloak-26.7.0 keycloak
sudo useradd -r -s /sbin/nologin keycloak
sudo chown -R keycloak:keycloak /opt/keycloak
```

Now the part that actually matters for the load balancer. Edit `/opt/keycloak/conf/keycloak.conf`:

```properties
# ---- Database (use RDS in real life, never the built-in dev database) ----
db=postgres
db-url=jdbc:postgresql://mydb.abc123.us-east-1.rds.amazonaws.com:5432/keycloak
db-username=keycloak
db-password=CHANGE_ME_USE_SECRETS_MANAGER

# ---- Public identity: this must match what users type in the browser ----
hostname=https://login.example.com

# ---- We are behind a proxy that already did the HTTPS work ----
proxy-headers=xforwarded
http-enabled=true
http-port=8080

# ---- Health checks for the ALB (served on port 9000) ----
health-enabled=true
metrics-enabled=true
```

Build and start it:

```bash
sudo -u keycloak /opt/keycloak/bin/kc.sh build

# First run only: create the very first admin account
sudo KC_BOOTSTRAP_ADMIN_USERNAME=admin \
     KC_BOOTSTRAP_ADMIN_PASSWORD='a-long-random-password' \
     -u keycloak /opt/keycloak/bin/kc.sh start
```

Confirm from inside the server that it's alive:

```bash
curl -I http://localhost:8080/realms/master     # expect HTTP/1.1 200
curl    http://localhost:9000/health/ready      # expect {"status": "UP", ...}
```

If those two commands don't work, **stop here and fix it.** The load balancer cannot save a server that isn't answering.

#### What those four Keycloak settings mean (in plain words)

| Setting | Plain meaning |
|---|---|
| `hostname=https://login.example.com` | "Whenever I write a link or a redirect, use this address — not my own private IP." |
| `proxy-headers=xforwarded` | "I trust the notes the load balancer staples to each request telling me who the real visitor was." |
| `http-enabled=true` | "It's OK for me to speak plain, unencrypted HTTP, because the load balancer handles the encryption for me." |
| `health-enabled=true` | "Turn on the little 'am I OK?' page at port 9000 so the load balancer can check on me." |

> ⚠️ **Version note (this changed recently):** Older tutorials tell you to set `KC_PROXY=edge` or `proxy=edge`. That option is **gone** in Keycloak 26. Use `proxy-headers=xforwarded` instead. Older tutorials also use `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`; in Keycloak 26 those were renamed to `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`.

Make it a real service so it survives a reboot — create `/etc/systemd/system/keycloak.service`:

```ini
[Unit]
Description=Keycloak
After=network.target

[Service]
User=keycloak
Group=keycloak
ExecStart=/opt/keycloak/bin/kc.sh start --optimized
Restart=on-failure
LimitNOFILE=102400

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now keycloak
```

---

### Step 4 — Create the target group

The target group is the ALB's address book: *which servers, on which port, and how do I know they're healthy?*

EC2 console → left menu → **Target Groups** → **Create target group**.

**Basic configuration**

| Field | Value | Why |
|---|---|---|
| Target type | **Instances** | Simplest. You'll pick EC2 instances by name. |
| Target group name | `keycloak-tg` | |
| Protocol / Port | **HTTP** / **8080** | The ALB speaks plain HTTP to Keycloak inside the private network. |
| VPC | your VPC | Must match the instance's VPC. |
| Protocol version | **HTTP1** | Keycloak is a normal web app. |

**Health checks** — expand this and change it. The defaults will not work well.

| Field | Value |
|---|---|
| Health check protocol | HTTP |
| Health check path | `/health/ready` |
| **Override port** | **9000** ← click "Override" and type this |
| Healthy threshold | 2 |
| Unhealthy threshold | 2 |
| Timeout | 5 seconds |
| Interval | 15 seconds |
| Success codes | `200` |

Click **Next**.

**Register targets:** tick your EC2 instance, make sure the port box says **8080**, click **Include as pending below**, then **Create target group**.

> 💡 **Why override the port to 9000?** Keycloak 26 serves its health page on a separate "management" port (9000) so that the public internet never sees it. Your ALB is inside the private network, so it *can* reach 9000 — but only because we opened that port to the ALB's security group in Step 2b. The public listener stays on 8080 only, so outsiders can never load `/health/ready`.
>
> **Don't want to use port 9000?** Then set the health path to `/realms/master` on port 8080 instead. That's a real page that returns `200`. What you must **not** do is leave the default path of `/`, because Keycloak's root path answers with a `302` redirect, and the default success code is `200` only — so the ALB would mark your perfectly healthy server as **unhealthy** forever. This is the #1 beginner trap.

---

### Step 5 — Create the load balancer

EC2 console → **Load Balancers** → **Create load balancer** → under *Application Load Balancer*, click **Create**.

**Basic configuration**

| Field | Value |
|---|---|
| Load balancer name | `keycloak-alb` |
| Scheme | **Internet-facing** (choose *Internal* if only your company network should reach it) |
| IP address type | **IPv4** (or *Dualstack* if you need IPv6) |

**Network mapping**

- VPC: your VPC
- Mappings: **tick at least two Availability Zones**, and in each one pick a **public subnet**.

> **Why two?** AWS will refuse to create the ALB with only one. This is a feature, not an annoyance: it forces your front door to survive one data center going dark. Your EC2 instance can still live in just one AZ for now.

**Security groups**

- Remove `default`. Select **`sg-alb-keycloak`**.

**Listeners and routing**

- Protocol **HTTPS**, Port **443** → Default action: forward to **`keycloak-tg`**.

**Secure listener settings**

- Security policy: **`ELBSecurityPolicy-TLS13-1-2-2021-06`** (this allows TLS 1.2 and 1.3, and blocks the old broken versions).
- Default SSL/TLS certificate: **From ACM** → pick the certificate you made in Step 1.

Click **Create load balancer**. It takes 2–5 minutes to go from *Provisioning* to **Active**.

When it's done, copy its **DNS name**. It looks like:

```
keycloak-alb-1234567890.us-east-1.elb.amazonaws.com
```

---

### Step 6 — Add the "http → https" redirect listener

Right now, if someone types `http://login.example.com`, nothing happens. Let's fix that politely.

1. Open your ALB → **Listeners and rules** tab → **Add listener**.
2. Protocol **HTTP**, port **80**.
3. Default action: **Redirect to URL**.
4. Set: Protocol `HTTPS`, Port `443`, keep host/path/query as *original*, Status code **301 – Permanently moved**.
5. Add.

Now everyone ends up on the encrypted version no matter what they type. 🎉

---

### Step 7 — Point your domain name at the ALB

The ALB has an ugly Amazon name. Let's give it your pretty one.

**If your DNS is in Route 53 (recommended):**

1. Route 53 → **Hosted zones** → `example.com` → **Create record**.
2. Record name: `login`
3. Record type: **A**
4. Toggle **Alias** to ON.
5. Route traffic to: *Alias to Application and Classic Load Balancer* → your region → your ALB.
6. Create.

**If your DNS is elsewhere:**

Create a **CNAME** record: `login` → `keycloak-alb-1234567890.us-east-1.elb.amazonaws.com`

> 🚫 **Never, ever look up the ALB's IP addresses and hard-code them.** An ALB's IPs change on its own schedule as AWS scales it up and down. If you pin an IP, your site will work great — until one random Tuesday when it doesn't. Always point at the **name**.
>
> An **Alias** record is better than a CNAME when you can use it: it's free to query, it resolves faster, and (unlike a CNAME) it can sit on the bare root domain `example.com` itself.

---

### Step 8 — Test it

Give DNS a few minutes, then:

```bash
# 1. Does the name resolve to the ALB?
dig +short login.example.com

# 2. Does the redirect work?
curl -I http://login.example.com
# expect: HTTP/1.1 301 Moved Permanently  /  Location: https://login.example.com:443/

# 3. Does HTTPS work and is the certificate right?
curl -I https://login.example.com/realms/master
# expect: HTTP/2 200

# 4. Is Keycloak using the right public name in its links?
curl -s https://login.example.com/realms/master/.well-known/openid-configuration | head -c 300
# every URL inside should start with https://login.example.com  -- NOT an internal IP
```

Then open a browser and go to **`https://login.example.com`**. You should see the Keycloak welcome/login page with a padlock in the address bar.

**Check the target group too:** EC2 → Target Groups → `keycloak-tg` → *Targets* tab. Your instance should say **healthy** in green. If it says *unhealthy* or *unused*, jump to [PART 7 — Troubleshooting](#10-part-7--troubleshooting-what-broke-and-why).

✅ **You're done with the build.** Everything below explains *why* it works, so you can fix it when it doesn't.

---

## 5. PART 2 — Background: what each piece really is

Now that it works, here's what you actually built.

### 5.1 What is Keycloak?

Keycloak is an **identity server**. Think of it as the bouncer with the guest list at a club.

Your apps (a website, a phone app, an internal dashboard) don't want to each store passwords — that's risky and repetitive. So instead they say: "Hey user, go talk to Keycloak. Come back with a wristband."

The user logs in at Keycloak once. Keycloak hands them a signed digital wristband called a **token**. The app checks the wristband's signature and says "yep, this is real, come in." That whole dance is called **OpenID Connect** (or **SAML**, the older version).

Two things about Keycloak matter enormously for load balancers:

1. **Keycloak writes its own address into everything it hands out.** Tokens contain an `issuer` field. Login pages contain redirect URLs. If Keycloak thinks its address is `http://10.0.1.55:8080`, it will tell users' browsers to go there — and their browsers can't reach a private IP. That's why `hostname=https://login.example.com` exists.
2. **Logging in is a multi-step conversation**, not one request. The browser bounces between pages several times. If those steps land on *different* servers that don't share memory, the login breaks. (More on that under "sticky sessions.")

### 5.2 What is a load balancer, really?

Imagine a doctor's office with five doctors. Patients don't wander the halls picking a door. There's a **receptionist**. The receptionist:

- Greets everyone at one known desk (the door everyone knows about)
- Knows which doctors are in today and which called in sick (**health checks**)
- Sends each patient to an available doctor (**load balancing**)
- Handles paperwork so the doctors don't have to (**TLS termination**)

That's a load balancer. AWS has three kinds:

| Type | Nickname | Works at | Understands | Use it when |
|---|---|---|---|---|
| **Application Load Balancer** | ALB | Layer 7 (application) | URLs, host names, headers, cookies | Web apps and APIs — **this is what Keycloak wants** |
| **Network Load Balancer** | NLB | Layer 4 (transport) | IP addresses and ports only | Extreme speed, non-HTTP protocols, need a fixed IP |
| **Gateway Load Balancer** | GWLB | Layer 3 | Raw packets | Feeding traffic through firewall appliances |

("Layer 7" vs "Layer 4" just means *how deeply it reads the mail*. An NLB reads the envelope. An ALB opens the envelope and reads the letter.)

### 5.3 What is a target group?

A target group is **a list plus a test**.

- **The list:** which servers, on which port.
- **The test:** the health check — a URL the ALB requests over and over.

Target groups are separate from load balancers on purpose. One ALB can point at many target groups, and you can swap which group a listener points to without rebuilding anything. That's how blue/green deployments work: build a new target group with new servers, flip the listener, done.

A target can be registered three ways:

| Target type | What you register | Good for |
|---|---|---|
| **Instance** | EC2 instance IDs | Normal EC2 setups (what we did) |
| **IP** | Raw IP addresses | Containers, on-premises servers reachable over VPN/Direct Connect |
| **Lambda** | A Lambda function | Serverless, no servers at all |
| **ALB** | Another ALB | When an NLB needs to hand off to an ALB |

### 5.4 What is a listener?

A listener is one **open ear** on the load balancer: a protocol and a port number.

- `HTTPS:443` — "I accept encrypted web traffic."
- `HTTP:80` — "I accept plain web traffic."

Every listener has a **default action** (what to do if no rule matches) and can have **rules**. A rule is an if/then:

> **IF** host header is `login.example.com` **AND** path starts with `/admin/*`
> **THEN** forward to target group `keycloak-admin-tg`

Rules are checked in **priority order** (lowest number first). The first match wins. The default action is the last resort. Rules can match on: host header, path, HTTP method, query string, source IP, and any HTTP header.

Available actions: `forward` (to a target group), `redirect` (bounce to another URL), `fixed-response` (return canned text), `authenticate-oidc`, `authenticate-cognito`.

> 😲 **Fun fact worth knowing:** the `authenticate-oidc` action means an ALB can *itself* make users log in through Keycloak before the request ever reaches your app. Your app then receives the user's identity in headers and needs almost no auth code. That's a whole other tutorial, but file it away.

### 5.5 What is a health check?

Every 15 seconds (our setting), the ALB opens a connection to each target and requests the health path. It's a nurse checking a pulse.

- If a target answers with a success code **N times in a row** (`healthy threshold`) → mark it **healthy** and send it traffic.
- If it fails or times out **N times in a row** (`unhealthy threshold`) → mark it **unhealthy** and stop sending traffic.

Unhealthy targets are not deleted. The ALB keeps checking them, and the moment they recover, traffic resumes automatically. This is self-healing, and it's free.

**Health check settings, decoded:**

| Setting | Means | Trade-off |
|---|---|---|
| Interval | Seconds between checks | Shorter = detect failures faster, but more load on the server |
| Timeout | How long to wait for an answer | Must be shorter than the interval |
| Healthy threshold | Passes needed to return to service | Higher = fewer flip-flops |
| Unhealthy threshold | Failures needed to pull from service | Lower = faster removal, but jumpier |
| Success codes | Which HTTP codes count as OK | Default `200`. Use `200-399` if your path redirects |

There are **two different kinds of health** worth understanding, and Keycloak exposes both:

- `/health/live` — "Is the process running at all?" If this fails, restart the server.
- `/health/ready` — "Is it fully started *and* is the database reachable?" If this fails, stop sending traffic but don't restart.

For an ALB you always want **`/health/ready`**. A Keycloak that's booted but can't reach its database would happily answer `/health/live` while failing every real login.

### 5.6 What is a security group?

A security group is a **stateful allow-list firewall** attached to a network interface.

- **Allow-list:** nothing gets through unless a rule explicitly permits it. There is no "deny" rule — you simply don't add an allow.
- **Stateful:** if a request is allowed in, the reply is automatically allowed out. You don't write return-trip rules.

The superpower we used: **a security group can reference another security group as its source.** That creates a relationship instead of an IP list — "whoever wears the ALB badge" rather than "these seventeen addresses." It keeps working even as AWS quietly adds and removes ALB nodes behind the scenes.

### 5.7 What is TLS, and what is "TLS termination"?

TLS turns your traffic into scrambled nonsense that only the two ends can unscramble. It also proves the server is who it claims to be, using the **certificate**.

**Termination** is where the scrambling stops. In our setup the scrambling stops **at the ALB** — this is called **edge termination**:

```
Browser ==encrypted==> ALB ---plain---> Keycloak
        (the internet)      (your private VPC)
```

Why this is normal and fine:
- The ALB does the expensive cryptography, not your server.
- The certificate lives in one place (ACM) and renews itself.
- The ALB can only apply rules based on host and path *because* it can read the request — impossible if traffic stayed encrypted end to end.
- The "plain" hop happens entirely inside your own VPC, which is not the public internet.

If your industry requires encryption on every single hop (healthcare, payments, government), see the "re-encrypt" option in [PART 6](#9-part-6--your-choices-with-pros-and-cons).

### 5.8 What is DNS and why the Alias record?

DNS is a phone book: names in, addresses out. Two record types matter here:

- **CNAME** — "this name is an alias for that other name." Works, but can't be used on a bare root domain like `example.com`, and adds an extra lookup.
- **Alias (Route 53 only)** — a special AWS record that resolves straight to the ALB's current IP addresses, updated automatically by AWS. Free to query, works on the root domain.

Use Alias when you can.


---

## 6. PART 3 — "What does an ALB need to be reachable at a host name?"

This is the question that trips up almost everyone. You asked it directly, so here's the full answer.

An ALB has its own Amazon name (`keycloak-alb-1234567890.us-east-1.elb.amazonaws.com`) that works out of the box. But making it answer to **your** name — `login.example.com` — requires **five separate things to agree with each other.** Miss any one and you get a confusing error.

### 6.1 The five things that must match

```
   [1] DNS RECORD          login.example.com -> the ALB
        |
   [2] CERTIFICATE         ACM cert whose name is login.example.com,
        |                  attached to the HTTPS listener
   [3] LISTENER            HTTPS on 443, exists and is running
        |
   [4] LISTENER RULE       (optional) if Host = login.example.com,
        |                  forward to keycloak-tg
   [5] APPLICATION CONFIG  Keycloak's own hostname setting says
                           https://login.example.com
```

Here's what actually goes wrong when each one is missing:

| Missing piece | Symptom you'd see |
|---|---|
| **1. DNS record** | Browser says "server not found." Nothing reaches AWS at all. |
| **2. Certificate** | Big scary red warning: "Your connection is not private / NET::ERR_CERT_COMMON_NAME_INVALID". The ALB served *a* certificate, just not one with your name on it. |
| **3. Listener** | Connection refused, or it just hangs. Nobody's listening on that port. |
| **4. Rule** | You reach the ALB but get the wrong app, or a `503`. Only matters if one ALB serves several sites. |
| **5. Keycloak's hostname** | The page *loads*, then everything after that is broken: redirect loops, "Invalid parameter: redirect_uri", broken CSS, tokens with the wrong issuer. **This is the sneaky one.** |

Notice that #5 is not an AWS setting at all. It's inside Keycloak. That's why people get stuck: the AWS side looks perfect and the app is still broken.

### 6.2 The Host header — the thing that carries the name

Every HTTP request a browser sends looks roughly like this:

```http
GET /realms/master/protocol/openid-connect/auth HTTP/1.1
Host: login.example.com
User-Agent: Mozilla/5.0 ...
```

That `Host:` line is the name the user typed. It travels *inside* the request, separate from the IP address the packet was routed to. This is how one server, at one IP, can host a hundred different websites — it reads the Host line to know which one you want. This is called **name-based virtual hosting**, and it's the foundation of host-based routing.

**The ALB passes the original `Host` header through to your target unchanged.** It does *not* rewrite it to the target's IP. That's helpful — Keycloak can see the real name.

But the ALB *does* change other things, so it adds a set of sticky notes:

| Header the ALB adds | Contains | Why Keycloak needs it |
|---|---|---|
| `X-Forwarded-For` | The real visitor's IP address | Otherwise every login looks like it came from the ALB. Breaks brute-force protection and audit logs. |
| `X-Forwarded-Proto` | `https` | The ALB talks to Keycloak over plain `http`. Without this note, Keycloak thinks the user is on an insecure connection and writes `http://` links. |
| `X-Forwarded-Port` | `443` | So generated URLs don't say `:8080`. |
| `X-Forwarded-Host` | `login.example.com` | Backup copy of the public name. |
| `X-Amzn-Trace-Id` | A unique request ID | For tracing one request across logs. |

**`proxy-headers=xforwarded` in your Keycloak config is what tells Keycloak to read those sticky notes.** Without it, Keycloak ignores them and believes it's a plain HTTP server on port 8080 — and everything downstream goes wrong.

> ⚠️ **Security warning, and this is a real one.** Those headers are just text. Anyone can fake them. Keycloak trusts them *completely* once you enable `proxy-headers`. That trust is only safe because your security group makes it physically impossible for anyone but the ALB to send Keycloak a request. **If you enable `proxy-headers` and also leave port 8080 open to `0.0.0.0/0`, an attacker can spoof their IP address and bypass your brute-force lockouts.** The firewall isn't optional — it's what makes the trust valid.

### 6.3 Host-based routing (running several sites on one ALB)

One ALB can front many applications. That's often the main reason to use an ALB at all, since ALBs cost money per hour and target groups are free.

On your HTTPS listener, add rules:

| Priority | Condition | Action |
|---|---|---|
| 10 | Host is `login.example.com` | forward → `keycloak-tg` |
| 20 | Host is `app.example.com` | forward → `webapp-tg` |
| 30 | Host is `api.example.com` AND path is `/v2/*` | forward → `api-v2-tg` |
| default | (anything else) | fixed-response `404` |

Requirements for this to work:

1. **Every host name needs a DNS record** pointing at the same ALB.
2. **Every host name needs to be on a certificate** attached to the listener. Either one certificate with several names (SANs), a wildcard cert (`*.example.com`), or several certificates added to the listener — an ALB supports multiple certs and picks the right one using **SNI** (the browser announces which name it wants during the TLS handshake, before the request is even sent).
3. Give the default action a real answer, like a `404` fixed-response, so unmatched traffic doesn't fall into your Keycloak by accident.

### 6.4 Internet-facing vs internal — the other meaning of "accessible"

| | Internet-facing | Internal |
|---|---|---|
| Gets | Public IP addresses | Private IPs only |
| Subnets required | **Public** subnets (with an Internet Gateway route) | Private subnets |
| Reachable from | Anywhere on Earth | Only inside the VPC, or over VPN / Direct Connect / peering |
| DNS name resolves to | Public IPs | Private IPs |
| Good for | A login page real customers use | Internal-only tools |

> ⚠️ **You cannot switch this later.** Scheme is fixed at creation. If you pick wrong, you delete the ALB and build a new one. Choose deliberately.

**The classic beginner failure:** you make an internet-facing ALB but put it in **private** subnets. AWS lets you do it. The ALB shows as *Active*. And nothing works, because there's no route to the internet. The fix is to check that the subnets you selected have a route table with `0.0.0.0/0 → igw-xxxx`.

Also: your ALB subnets need at least a **/27** with **8 free IP addresses** in each AZ, because the ALB places nodes there and needs headroom to scale.


---

## 7. PART 4 — The full journey of one request

Let's follow a single click all the way through. This is the payoff — once this makes sense, you can debug almost anything.

**A user types `login.example.com` and hits Enter.**

**1 — Name lookup.**
The browser asks DNS: "Where is `login.example.com`?" Route 53 answers with the ALB's current public IP addresses (usually two or more, one per AZ).

**2 — Connection.**
The browser opens a TCP connection to one of those IPs on port 443.

**3 — Firewall check #1.**
The traffic hits `sg-alb-keycloak`. Rule says "443 from anywhere: allowed." ✅

**4 — TLS handshake.**
The browser says "I want `login.example.com`" (that's SNI). The ALB finds the matching certificate, presents it, and the two agree on encryption keys. The padlock appears. Everything from here on is scrambled.

**5 — The request arrives.**
The browser sends `GET / HTTP/1.1` with `Host: login.example.com`. The ALB decrypts it and can now read it.

**6 — Rule evaluation.**
The listener runs its rules in priority order. Host matches → forward to `keycloak-tg`.

**7 — Target selection.**
The ALB looks at `keycloak-tg` and picks a **healthy** target. (Only one server? Then it picks that one. Several? Round-robin by default, or "least outstanding requests" if you turned that on.)

**8 — Sticky notes attached.**
The ALB adds `X-Forwarded-For: 203.0.113.9`, `X-Forwarded-Proto: https`, `X-Forwarded-Port: 443`, `X-Amzn-Trace-Id: ...`, and keeps `Host: login.example.com` as-is.

**9 — New connection to the target.**
The ALB opens a **separate**, plain-HTTP connection to `10.0.1.55:8080`. This is a brand-new connection — the browser's connection ends at the ALB. (This is exactly why it's called a *proxy*.)

**10 — Firewall check #2.**
Traffic hits `sg-ec2-keycloak`. Rule says "8080 from `sg-alb-keycloak`: allowed." The packet is coming from an ALB node wearing that badge. ✅

**11 — Keycloak thinks.**
Keycloak reads the sticky notes (because `proxy-headers=xforwarded`). It concludes: *this user came over HTTPS, to login.example.com, on port 443, from IP 203.0.113.9.* It renders the login page and, crucially, writes every link and form action as `https://login.example.com/...`.

**12 — The reply goes back.**
Keycloak → ALB → (re-encrypted) → browser. Security groups are stateful, so no return rules were needed.

**13 — Meanwhile, in the background.**
Independently of all this, every 15 seconds the ALB has been requesting `http://10.0.1.55:9000/health/ready` and getting `200 OK`. That's the only reason step 7 considered this server at all.

**14 — The login continues.**
The user types a password and submits. That's another whole trip through steps 2–12. Keycloak checks the password against RDS, creates a session, sets cookies, and redirects the browser to the original app with an authorization code. The app trades that code for a token — a **back-channel** call, which may go through the ALB too.

> 🧠 **The step-11 insight is the one to keep.** Almost every "Keycloak behind a load balancer" bug is Keycloak generating the *wrong URL* because it didn't know its own public name. The AWS parts fail loudly (timeouts, 502s). The hostname parts fail quietly (weird redirects, broken CSS, invalid `redirect_uri`).

---

## 8. PART 5 — Best practices (2026)

### Security

- **Force HTTPS everywhere.** HTTP listener does nothing but 301-redirect to HTTPS. Never forward plain HTTP to Keycloak.
- **Use a modern TLS policy.** `ELBSecurityPolicy-TLS13-1-2-2021-06` is the sensible default. Only allow TLS 1.0/1.1 if you have an ancient client you cannot replace — and know that it fails most compliance audits.
- **Never open Keycloak's port to `0.0.0.0/0`.** Security-group-to-security-group references only. This is not paranoia; it's what makes `proxy-headers` safe (see §6.2).
- **Never expose port 9000 publicly.** No listener should point at it. Health and metrics endpoints leak information about your internals.
- **Set `hostname` explicitly** rather than using `hostname-strict=false`. The `false` setting tells Keycloak "just believe whatever the Host header says," which is convenient for a laptop and a bad idea on the internet.
- **Put AWS WAF in front of the ALB.** ALB integrates with WAF in a couple of clicks. The AWS managed rule sets block a lot of automated garbage, and rate-based rules blunt credential-stuffing against a login page — which is exactly the kind of target Keycloak is.
- **Turn on access logs** (to S3) and **connection logs**. Free-ish, and the first thing you'll want when something goes wrong. Enable them *before* you need them.
- **Enable deletion protection** on the ALB. One misclick shouldn't take down every login in your company.
- **Store the database password in AWS Secrets Manager**, not in `keycloak.conf` in plaintext.
- **Enable "Drop invalid header fields"** on the ALB (there's an attribute for it) and consider the **desync mitigation mode** setting at `defensive` or `strictest`.

### Reliability

- **Run at least two EC2 instances in two AZs.** One instance means one reboot = everyone locked out of everything. Since Keycloak *is* the front door to all your other apps, its outage is the worst kind.
- **Use RDS (Multi-AZ) for the database,** not the built-in dev database. The dev database is explicitly not for production and loses data.
- **Put the instances in an Auto Scaling Group** attached to the target group. Then a dead instance is replaced automatically and registers itself.
- **Enable cross-zone load balancing** — on ALBs it's on by default and free. It lets AZ-A's ALB node send traffic to a server in AZ-B, which prevents lopsided load.
- **Set deregistration delay (connection draining)** to ~30 seconds. When you remove a server, in-flight requests finish instead of being cut off mid-login.
- **Handle sticky sessions.** With more than one Keycloak node, the multi-step login flow needs to keep landing on the same server. Two workable approaches:
  - Enable **application-based stickiness** on the target group using Keycloak's own cookie name `AUTH_SESSION_ID` (this is what the Keycloak docs recommend for proxies), or
  - Enable simple **duration-based stickiness** (`lb_cookie`) with a 1-hour duration. Cruder, but works.

  Stickiness is a performance optimization, not a correctness requirement, *if* your Keycloak nodes are properly clustered — but getting Infinispan clustering right on plain EC2 is genuinely hard, so most people use stickiness.
- **Health check `/health/ready`, not `/`.** Say it with me one more time.
- **Idle timeout:** ALB default is 60 seconds. Fine for Keycloak. Make sure your app's timeout is *longer* than the ALB's, not shorter, to avoid a race where the ALB reuses a connection the server just closed.

### Operations

- **Tag everything** (`Name`, `Environment`, `Owner`). In six months you will not remember what `keycloak-tg-2` was for.
- **Watch these CloudWatch metrics:** `UnHealthyHostCount`, `HTTPCode_ELB_5XX_Count`, `HTTPCode_Target_5XX_Count`, `TargetResponseTime`, `RejectedConnectionCount`. Alarm on the first two at minimum.
- **Build it with Terraform or CloudFormation**, not by clicking. You'll rebuild this in staging and prod, and click-built infrastructure drifts.
- **Test failover on purpose.** Stop Keycloak on one instance and watch the target group notice. Do this in business hours, deliberately, rather than discovering how it behaves at 2 a.m.
- **Keep Keycloak patched.** Keycloak ships security fixes constantly, and only the latest major line gets them. As of July 2026 the current release is **26.7.0**, and 26.6 already reached end of life — this project moves fast.

---

## 9. PART 6 — Your choices, with pros and cons

### Choice 1: ALB vs NLB vs CloudFront in front of Keycloak

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **ALB** | Host/path routing; free ACM certs; health checks on real URLs; WAF integration; can do the OIDC auth action itself | Costs ~$16+/month even when idle; IP addresses change; slightly higher latency than NLB | ✅ **Default choice for Keycloak** |
| **NLB** | Extremely fast; static/Elastic IPs possible; can pass TLS straight through | No host/path routing; no WAF; you must manage certs on Keycloak yourself; can't add `X-Forwarded-*` headers in TCP mode | Only if you need a fixed IP or true end-to-end TLS |
| **CloudFront → ALB** | Global edge caching; DDoS protection via Shield; TLS terminates near the user | More moving parts; caching a login page needs care; more places for the host name to get mangled | Good for global user bases; overkill for one office |
| **Nginx/Traefik on EC2** | Total control; cheap; runs anywhere | You now own patching, HA, and cert renewal for the proxy itself | Fine for a lab, poor use of your time in AWS |

### Choice 2: Where does TLS stop?

| Option | How it works | Pros | Cons |
|---|---|---|---|
| **Edge termination** (what we built) | Browser→ALB encrypted; ALB→EC2 plain HTTP | Simplest; free auto-renewing cert; ALB can read and route | Traffic is unencrypted inside your VPC |
| **Re-encryption** | ALB decrypts, then re-encrypts to the target using HTTPS | Encrypted on every hop; ALB can still route | Keycloak needs its own cert; more CPU; more to renew. (Note: the ALB does **not** validate the target's certificate, so a self-signed one is acceptable here) |
| **Passthrough** | Encryption never breaks until it reaches Keycloak (requires NLB) | Truest end-to-end encryption | Lose all Layer-7 features; no host routing, no WAF, no header injection |

For most people, edge termination is correct. Choose re-encryption if a compliance framework demands encryption in transit *everywhere*.

### Choice 3: Target type — Instance vs IP

| | Instance | IP |
|---|---|---|
| Register by | EC2 instance ID | IP address |
| Pros | Simple; ASG can auto-register | Works for containers, and for servers outside AWS over VPN |
| Cons | EC2 only | You manage the list yourself, and IPs change on reboot unless static |

Use **Instance** unless you have a specific reason not to.

### Choice 4: One Keycloak node vs a cluster

| | Single node | Two or more nodes |
|---|---|---|
| Cost | Lower | Roughly double, plus RDS |
| Availability | Reboot = total outage | Survives losing a server or an AZ |
| Complexity | Very low | Needs shared DB, sticky sessions or working Infinispan clustering |
| Honest advice | Fine for dev/test and demos | **Required** for anything real — Keycloak is a single point of failure for every app behind it |

### Choice 5: Where to run Keycloak at all

| Option | Pros | Cons |
|---|---|---|
| **EC2** (this tutorial) | Full control; easy to understand; easy to debug by SSH | You patch the OS, the JVM, and Keycloak yourself |
| **ECS Fargate** | No servers to patch; scales cleanly; ALB integrates natively | Container knowledge required; clustering config is fiddlier |
| **EKS + Keycloak Operator** | The officially blessed HA path; upstream ships an Operator | Kubernetes is a large thing to adopt just for a login server |
| **Managed Keycloak / Red Hat build of Keycloak** | Someone else's problem; supported | Costs money; less control |

---

## 10. PART 7 — Troubleshooting: what broke and why

Work top to bottom. The order roughly matches how often each one bites people.

### Target shows "unhealthy"

| Check | How |
|---|---|
| Is Keycloak actually running? | SSH in: `sudo systemctl status keycloak` |
| Does the health URL work locally? | `curl -v http://localhost:9000/health/ready` |
| Did you set `health-enabled=true`? | Without it, port 9000 isn't even listening |
| Does the security group allow the health port from the ALB's SG? | Easy to open 8080 and forget 9000 |
| Is the health path returning a redirect? | Default path `/` returns `302`; default success code is `200`. Mismatch = permanently unhealthy |
| Is the timeout too short? | Keycloak can take 60+ seconds to boot. Give it a healthy threshold of 2 and be patient after a restart |

### `503 Service Temporarily Unavailable`

This is the ALB saying: *"I have nowhere to send this."* It almost always means **zero healthy targets**, or no target group is registered on that listener rule at all. Go fix the health check.

### `502 Bad Gateway`

The ALB reached the target but the reply was unusable. Usual causes: Keycloak crashed mid-request (check its logs and the JVM heap), the target is speaking HTTPS while the target group says HTTP (or vice versa), or the app closed the connection early.

### `504 Gateway Timeout`

The target didn't answer within the idle timeout. Usually a slow database query, an undersized instance, or a security group that's silently dropping packets rather than rejecting them.

### `403 Forbidden` on login POSTs, but pages load fine

Classic Keycloak-behind-a-proxy signature. Keycloak does an **origin check** on form submissions, and without `proxy-headers` set, the origin it computes doesn't match the one the browser sent. Set `proxy-headers=xforwarded` and restart.

### Infinite redirect loop / "too many redirects"

Keycloak thinks the connection is insecure and keeps redirecting to HTTPS, while the ALB keeps handing it plain HTTP. It's not reading `X-Forwarded-Proto`. Same fix: `proxy-headers=xforwarded` plus `http-enabled=true`.

### Login page loads but CSS and images are broken, or `redirect_uri` is invalid

Keycloak is writing URLs with the wrong host or port — typically its private IP or `:8080`. Fix `hostname=https://login.example.com` and rebuild/restart. Verify with:

```bash
curl -s https://login.example.com/realms/master/.well-known/openid-configuration | grep -o 'https://[^"]*' | head
```

Every URL should show your public name.

### Certificate warning in the browser

The name on the cert doesn't match what was typed (`login.example.com` vs `www.login.example.com`), or the cert is in a different AWS region than the ALB, or it's still *Pending validation*, or it expired because someone deleted the DNS validation record.

### Login randomly fails, or users get logged out at random

Multiple Keycloak nodes without stickiness or working clustering. The login flow bounced to a different server that had never heard of this session. Turn on stickiness.

### It worked yesterday and today the site is unreachable

Somebody hard-coded the ALB's IP address in DNS. See Step 7. Use an Alias or CNAME to the ALB's **name**.

### Everything times out and there's nothing in the ALB logs

Traffic never arrived. Check: is the ALB *internet-facing*? Are its subnets **public** (route table has `0.0.0.0/0 → igw-`)? Does `sg-alb-keycloak` allow 443 inbound from `0.0.0.0/0`? Does a Network ACL block it?


---

## 11. PART 8 — The same thing with copy-paste CLI commands

If you'd rather type than click, here's the whole build. Replace the placeholder values at the top.

```bash
# ---- Fill these in ----
VPC_ID=vpc-0123456789abcdef0
SUBNET_A=subnet-0aaa111
SUBNET_B=subnet-0bbb222
INSTANCE_ID=i-0abc123keycloak
CERT_ARN=arn:aws:acm:us-east-1:111122223333:certificate/abcd-1234
REGION=us-east-1

# ---- 1. Security group for the ALB ----
ALB_SG=$(aws ec2 create-security-group \
  --group-name sg-alb-keycloak \
  --description "Public entry point for Keycloak" \
  --vpc-id $VPC_ID --region $REGION \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 443 --cidr 0.0.0.0/0 --region $REGION
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 --region $REGION

# ---- 2. Security group for the EC2 instance ----
EC2_SG=$(aws ec2 create-security-group \
  --group-name sg-ec2-keycloak \
  --description "Keycloak app server - ALB only" \
  --vpc-id $VPC_ID --region $REGION \
  --query 'GroupId' --output text)

# NOTE: --source-group, not --cidr. This is the important bit.
aws ec2 authorize-security-group-ingress --group-id $EC2_SG \
  --protocol tcp --port 8080 --source-group $ALB_SG --region $REGION
aws ec2 authorize-security-group-ingress --group-id $EC2_SG \
  --protocol tcp --port 9000 --source-group $ALB_SG --region $REGION

# ---- 3. Target group ----
TG_ARN=$(aws elbv2 create-target-group \
  --name keycloak-tg \
  --protocol HTTP --port 8080 --vpc-id $VPC_ID \
  --target-type instance --protocol-version HTTP1 \
  --health-check-protocol HTTP \
  --health-check-path /health/ready \
  --health-check-port 9000 \
  --health-check-interval-seconds 15 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --region $REGION \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 register-targets --target-group-arn $TG_ARN \
  --targets Id=$INSTANCE_ID,Port=8080 --region $REGION

# Connection draining: let in-flight requests finish
aws elbv2 modify-target-group-attributes --target-group-arn $TG_ARN \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 \
  --region $REGION

# ---- 4. The load balancer ----
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name keycloak-alb \
  --type application --scheme internet-facing --ip-address-type ipv4 \
  --subnets $SUBNET_A $SUBNET_B \
  --security-groups $ALB_SG \
  --region $REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN --region $REGION

# ---- 5. HTTPS listener ----
aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTPS --port 443 \
  --certificates CertificateArn=$CERT_ARN \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN \
  --region $REGION

# ---- 6. HTTP listener that just redirects ----
aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions '[{"Type":"redirect","RedirectConfig":{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}}]' \
  --region $REGION

# ---- 7. Useful hardening ----
aws elbv2 modify-load-balancer-attributes --load-balancer-arn $ALB_ARN \
  --attributes \
    Key=deletion_protection.enabled,Value=true \
    Key=routing.http.drop_invalid_header_fields.enabled,Value=true \
    Key=routing.http.desync_mitigation_mode,Value=defensive \
  --region $REGION

# ---- 8. Get the DNS name to point your domain at ----
aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --region $REGION --query 'LoadBalancers[0].DNSName' --output text

# ---- 9. Watch health status until it says healthy ----
watch -n 5 "aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --region $REGION --query 'TargetHealthDescriptions[].TargetHealth.State' --output text"
```

---

## 12. PART 9 — What this costs

Rough US-region numbers as of mid-2026. **Always check the current AWS pricing page** — these change, and they vary a lot by region.

| Item | Approximate cost |
|---|---|
| Application Load Balancer | ~$0.0225 per hour ≈ **$16–17/month**, running or not |
| ALB capacity units (LCU) | Usually pennies to a few dollars/month at small scale |
| ACM public certificate | **$0** |
| Route 53 hosted zone | ~$0.50/month |
| Route 53 Alias queries to an ALB | **$0** |
| EC2 `t3.medium` | ~$30/month on-demand |
| RDS `db.t4g.micro` PostgreSQL | ~$15/month |
| Data transfer out | First 100 GB/month free, then ~$0.09/GB |

**Small realistic production setup:** roughly $80–120/month for two EC2 instances, an ALB, and a small RDS.

Two ways to trim it:
- **Share one ALB across several apps** using host-based rules. The ALB is the fixed cost; extra target groups and rules are free.
- **Reserved Instances or Savings Plans** cut the EC2 and RDS portion substantially if you're committing for a year.

---

## 13. PART 10 — One-page cheat sheet

Print this and stick it on your wall.

### The chain, in order

```
Domain name  ->  ACM certificate  ->  HTTPS:443 listener  ->  listener rule
   ->  target group (with health check)  ->  EC2 instance  ->  Keycloak on 8080
```

### The five must-match items for a working host name

1. DNS record → the ALB (Alias, or CNAME to the ALB's **name**)
2. ACM certificate covering that exact name, **in the same region**
3. HTTPS:443 listener with that certificate attached
4. Listener rule (or default action) forwarding to the right target group
5. `hostname=https://login.example.com` inside Keycloak's own config

### Keycloak's four load-balancer settings

```properties
hostname=https://login.example.com
proxy-headers=xforwarded
http-enabled=true
health-enabled=true
```

### The security group pattern

```
Internet  --443-->  [sg-alb-keycloak]  --8080/9000-->  [sg-ec2-keycloak]
                                        ^
                          source = the SG ID, never 0.0.0.0/0
```

### Health check settings that actually work

```
Path: /health/ready    Port override: 9000    Success codes: 200
Interval: 15s   Timeout: 5s   Healthy: 2   Unhealthy: 2
```

### Error codes, decoded

| Code | Means |
|---|---|
| `503` | ALB has no healthy targets |
| `502` | Target answered with garbage, or crashed |
| `504` | Target was too slow |
| `403` on POST | Keycloak origin check — you forgot `proxy-headers` |
| Redirect loop | Keycloak doesn't know it's behind HTTPS |
| Cert warning | Wrong name, wrong region, or not validated |

### The three rules to never break

1. **Never expose Keycloak's port to the internet.** SG-to-SG only.
2. **Never hard-code the ALB's IP addresses.** Use the name.
3. **Always tell Keycloak its own public hostname.** It cannot guess.

---

## 14. Where to read more

**Keycloak (official)**
- Configuring a reverse proxy — `keycloak.org/server/reverseproxy`
- Configuring the hostname (v2) — `keycloak.org/server/hostname`
- Health checks — `keycloak.org/observability/health`
- Configuring for production — `keycloak.org/server/configuration-production`
- Release notes — `keycloak.org/docs/latest/release_notes/`

**AWS (official)**
- Application Load Balancer User Guide
- Target groups for your ALB
- Health checks for your target groups
- Security groups for your ALB
- ELB pricing page

**Try this next**
- Rebuild the whole thing in Terraform so it's reproducible.
- Add AWS WAF with a rate-based rule on `/realms/*/protocol/openid-connect/token`.
- Add a second EC2 instance in the other AZ and turn on stickiness.
- Explore the ALB's `authenticate-oidc` action — let the load balancer itself require a Keycloak login before requests reach your app.

---

*Written for someone brand new to AWS load balancers. If a section didn't land, the fastest way to make it click is to build it once in a throwaway account and then deliberately break one piece at a time — unregister the target, delete the DNS record, remove the certificate — and watch what error each one produces. Ten minutes of that teaches more than any diagram.*