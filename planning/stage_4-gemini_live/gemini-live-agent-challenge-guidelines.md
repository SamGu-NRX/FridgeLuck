# Gemini Live Agent Challenge — Guidelines & Requirements

**Sources:** [Devpost](https://geminiliveagentchallenge.devpost.com/) | [Official Rules](https://geminiliveagentchallenge.devpost.com/rules) | [YouTube intro](https://www.youtube.com/watch?v=-AAwoj4qN8M)
**Deadline:** March 16, 2026 @ 5:00pm PDT

---

## Overview

**Tagline:** _Redefining Interaction: From Static Chatbots to Immersive Experiences_

> Hey builders! Stop typing, and start interacting! We are moving beyond the text box. The future isn't about just chatting with AI—it's about immersive, real-time experiences. To celebrate the power of multimodal AI, we're challenging you to build the next generation of agents that can help you **see** 🙈, **hear** 🙉, **speak** 🙊, and **create**.

**Themes:** Communication | Machine Learning/AI | Voice skills
**Format:** Online, Public

---

## Schedule

| Period                | Begins                   | Ends                 |
| --------------------- | ------------------------ | -------------------- |
| **Submissions**       | February 16, 10:15am PST | March 16, 5:00pm PDT |
| **Judging**           | March 17, 9:00am PDT     | April 8, 5:00pm PDT  |
| **Winners Announced** | April 24, 9:00am PDT     | —                    |

---

## What to Build

Entrants must develop a **NEW** next-generation AI Agent that:

- Uses **multimodal inputs and outputs**
- Moves **beyond simple text-in/text-out** interactions
- Leverages **Google's Live API** with video/image generation
- Solves complex problems or creates new user experiences

### Universal Requirements (All Projects)

1. **Leverage a Gemini model** (e.g. Gemini 2.0, Gemini Nano)
2. **Build with** Google GenAI SDK **or** ADK (Agent Development Kit)
3. **Use at least one Google Cloud service** — e.g. Firestore, Cloud SQL, Cloud Storage, Cloud Run, Vertex AI
4. **Host agents on Google Cloud**
5. Abide by [Google Cloud Acceptable Use Policy](https://cloud.google.com/terms/aup)

**Resources:** Quick starts, tutorials, and webinars hosted by Google experts are available — check the hackathon homepage and video description.

---

## Project Categories

### 1. Live Agents 🗣️

**Focus:** Real-time Interaction (Audio/Vision)

**Description:** Build an agent that users can talk to naturally and can be interrupted. Examples:

- Real-time translator
- Vision-enabled tutor that "sees" your homework
- Customer support voice agent that handles interruptions gracefully
- Crisis negotiator

**Mandatory Tech:**

- Gemini Live API **or** ADK
- Agents hosted on Google Cloud

---

### 2. Creative Storyteller ✍️

**Focus:** Multimodal Storytelling with Interleaved Output

**Description:** Build an agent that thinks and creates like a creative director, seamlessly weaving together text, images, audio, and video in a single, fluid output stream. Leverage Gemini's native interleaved output for rich, mixed-media responses.

**Examples:**

- Interactive storybooks (text + generated illustrations inline)
- Marketing asset generator (copy + visuals + video in one go)
- Educational explainers (narration woven with diagrams)
- Social content creator (caption + image + hashtags together)

**Mandatory Tech:**

- Gemini's **interleaved/mixed output** capabilities
- Agents hosted on Google Cloud

---

### 3. UI Navigator ☸️

**Focus:** Visual UI Understanding & Interaction

**Description:** Build an agent that becomes the user's hands on screen. The agent observes the browser or device display, interprets visual elements (with or without APIs/DOM access), and performs actions based on user intent.

**Examples:**

- Universal web navigator
- Cross-application workflow automator
- Visual QA testing agent (agent interprets screens like a browser or device display)

**Mandatory Tech:**

- Gemini **multimodal** to interpret screenshots/screen recordings
- Output **executable actions**
- Agents hosted on Google Cloud

---

## Submission Requirements

### Required

| Item                        | Details                                                                                                                                                                                                                    |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Text Description**        | Summary of features, functionality, technologies, data sources, findings/learnings                                                                                                                                         |
| **Public Code Repository**  | URL with spin-up instructions in README for reproducibility                                                                                                                                                                |
| **Architecture Diagram**    | Clear visual of system (Gemini ↔ backend ↔ database ↔ frontend). _Pro tip: Add to file upload or image carousel_                                                                                                           |
| **Proof of GCP Deployment** | **Separate from demo video.** (1) Short screen recording showing backend on GCP (e.g. console logs, Cloud Run dashboard, live URL), or (2) Link to code file demonstrating GCP service usage (e.g. API calls to Vertex AI) |
| **Demonstration Video**     | <4 min; English or subtitles; uploaded to YouTube or Vimeo; public link                                                                                                                                                    |

### Demonstration Video Must

- Demo multimodal/agentic features **working in real-time** (no mockups)
- Pitch the project: problem solved + value delivered
- Show actual software in action

### Additional Rules (from [Official Rules](https://geminiliveagentchallenge.devpost.com/rules))

- **Category selection** — Select **one** category; Sponsor/Administrator may reassign if applicable
- **New projects only** — Created during Contest Period, original work (not a modification of existing work)
- **No financial/preferential support** — Project must NOT have been developed with funding, investment, contract, or commercial license from Google or Devpost prior to end of Submission Period
- **Functionality** — Must install and run consistently; function as depicted in video/description
- **Testing access** — Provide link to working demo or test build; include login credentials if private; free for judges until Judging Period ends
- **Language** — Minimum English support; all submission materials in English (or provide translation)
- **Third-party integrations** — Must be authorized; indicate in submission with specificity
- **Multiple submissions** — Allowed if each is unique and substantially different (Sponsor/Devpost discretion)
- **Submission ownership** — Original work, solely owned, no IP violations; open source OK if you enhance/build upon it

### Content Restrictions (disqualifying)

- No derogatory, offensive, threatening, defamatory, disparaging, libelous, sexual, profane, discriminatory content
- No third-party advertising, slogans, logos, or sponsorship/endorsement
- No violations of third-party publicity, privacy, or intellectual property rights
- Must comply with theme and spirit of the Contest

### Submission Modifications

- **Before deadline:** Save drafts to Devpost portfolio; submit when ready
- **After deadline:** No changes to submission; may continue updating project in Devpost portfolio
- Sponsor/Devpost may permit modifications only to remove infringing material, PII, or inappropriate content

---

## Bonus Points (Optional)

| Bonus                            | Max Points | Details                                                                                                                 |
| -------------------------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------- |
| **GDG Membership**               | +0.2       | Active Google Developer Group member; link to public profile ([gdg.community.dev](https://gdg.community.dev/))          |
| **Automated Cloud Deployment**   | +0.2       | Scripts or IaC for deployment; code in public repo                                                                      |
| **Content (blog/podcast/video)** | +0.6       | Cover how project was built with Google AI + Cloud; include "created for this hackathon"; use #GeminiLiveAgentChallenge |

**Final score:** 1–6 (base 1–5 + up to 1.0 bonus)

---

## Judging Criteria

**Scoring:** 1–5 per criterion, averaged per submission. Weighted as below.

### 1. Innovation & Multimodal User Experience (40%)

- **Fluidity:** Is the experience "Live" and context-aware, or disjointed and turn-based?
- **Category-specific:**
  - **UI Navigator:** Does the agent demonstrate visual precision (understanding screen context) rather than blind clicking?
  - **Storyteller:** Is media interleaved (text, image, audio) seamlessly into a coherent narrative?
  - **Live Agent:** Does the agent handle interruptions (barge-in) naturally? Distinct persona/voice?
- **"Beyond Text" Factor:** Does the project break the text-box paradigm? Is interaction natural, immersive, superior to standard chat? Does the agent "See, Hear, and Speak" seamlessly?

### 2. Technical Implementation & Agent Architecture (30%)

- **Robustness:** Does the agent avoid hallucinations? Evidence of grounding?
- **System Design:** Is agent logic sound? Handles errors, API timeouts, edge cases gracefully?
- **Google Cloud Native:** Effective use of GenAI SDK or ADK? Backend robustly hosted on GCP (Cloud Run, Vertex AI, Firestore)?

### 3. Demo & Presentation (30%)

- **"Live" Factor:** Does the video show actual software working (not mockups)?
- **Proof:** Clear architecture diagram? Visual proof of Cloud deployment?
- **Story:** Does the video clearly define problem and solution?

### Judging Stages

1. **Stage One:** Pass/fail — meets baseline (all requirements, addresses challenge, applies requirements)
2. **Stage Two:** Scored on criteria above
3. **Stage Three:** Bonus contributions applied

**Subcategory prizes:** Determined by top score in each individual criterion. If a project wins both a category prize and subcategory prize, subcategory goes to next highest.

**Winner verification:** Potential winners notified ~April 8; must respond within 2 days. Required Forms (affidavit, etc.) due within 10 business days. One prize per submission max.

---

## Project Team

- Submit as **individual**, **team**, or **organization**
- Team: all members must be added on Devpost; appoint one **Representative** to act on behalf
- Organizations must exist and be incorporated at time of entry

---

## Awards

| Award                                             | Category                               |
| ------------------------------------------------- | -------------------------------------- |
| **Grand Prize**                                   | Highest-scoring across all submissions |
| **Best of Live Agents**                           | Live Agents category                   |
| **Best of Creative Storytellers**                 | Creative Storyteller category          |
| **Best of UI Navigators**                         | UI Navigator category                  |
| **Best Multimodal Integration & User Experience** | Top score in that criterion            |
| **Best Technical Execution & Agent Architecture** | Top score in that criterion            |
| **Best Innovation & Thought Leadership**          | Top score in that criterion            |
| **Honorable Mentions** (5)                        | Runners up                             |

Grand Prize includes trip to Google Cloud Next 2026 (Las Vegas). Subcategory prizes go to next highest if project already won a category prize.

---

## Key Links

- **Contest site:** [geminiliveagentchallenge.devpost.com](https://geminiliveagentchallenge.devpost.com/)
- **Full rules:** [geminiliveagentchallenge.devpost.com/rules](https://geminiliveagentchallenge.devpost.com/rules)
- **Schedule:** [geminiliveagentchallenge.devpost.com/details/dates](https://geminiliveagentchallenge.devpost.com/details/dates)
- **YouTube intro:** [Build Multimodal AI Agents](https://www.youtube.com/watch?v=-AAwoj4qN8M)
- **Google Cloud free trial:** [cloud.google.com/free](https://cloud.google.com/free)
- **Questions:** shawni@devpost.com

---

## Checklist for Submitters

**Critical (from video + rules):** (1) Public code repo, (2) Architecture diagram + setup guide showing Gemini/ADK integration, (3) Demo video <4 min with agent working in real time (no mockups), (4) Proof of GCP deployment — can be separate recording or code file link.

- [ ] New project built during Contest Period
- [ ] Uses Gemini model + GenAI SDK or ADK + ≥1 Google Cloud service
- [ ] Fits one category (Live Agents / Creative Storyteller / UI Navigator)
- [ ] Meets category-specific mandatory tech
- [ ] Public code repo with README spin-up instructions
- [ ] Architecture diagram (visible in submission)
- [ ] Proof of GCP deployment (separate recording or code file link)
- [ ] Demo video <4 min, English, real-time working demo (no mockups)
- [ ] Video pitches problem + solution + value
- [ ] Optional: GDG profile, automated deployment, content piece (#GeminiLiveAgentChallenge)
- [ ] No financial/preferential support from Google/Devpost; no content restrictions violated
