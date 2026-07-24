import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Serves the public "share this prompt outside the platform" page
// server-side (instead of the static prompt.html this replaced) so that
// link-preview crawlers -- WhatsApp, iMessage, Twitter, Facebook -- see
// an og:image tag pointing at the ACTUAL prompt's banner before any
// JavaScript runs. A static file can't do this: every prompt would share
// the same generic preview card since the meta tags are fixed at build
// time, not per-request.

const SITE = 'https://apexfictionstudio.com'
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function escHtml(s: unknown): string {
  return String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#x27;')
}

function briefToHtml(raw: string | null): string {
  return String(raw || '').split(/\n{2,}/).map(par =>
    `<p>${escHtml(par.trim()).replace(/\n/g, '<br>')}</p>`).join('')
}

function plainSnippet(raw: string | null, max: number): string {
  const flat = String(raw || '').replace(/\s+/g, ' ').trim()
  return flat.length > max ? flat.slice(0, max - 1).trimEnd() + '…' : flat
}

type Prompt = {
  id: string
  title: string
  brief: string | null
  genre: string | null
  banner_url: string | null
  tags: string[] | null
  sample_chapter_url: string | null
}

function pageShell(head: string, body: string): string {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<link rel="icon" type="image/svg+xml" href="${SITE}/assets/afs-favicon.svg"/>
<link rel="icon" type="image/png" sizes="32x32" href="${SITE}/assets/favicon-32.png"/>
<link rel="apple-touch-icon" sizes="192x192" href="${SITE}/assets/favicon-192.png"/>
<meta name="robots" content="noindex, follow"/>
${head}
<script src="https://cdn.tailwindcss.com"></script>
<script>
  tailwind.config = {
    theme: {
      extend: {
        colors: {
          obsidian: '#121212', charcoal: '#1C1C1C', surface: '#242424', border: '#2E2E2E',
          gold: '#C9A84C', 'gold-light': '#E2C97E', crimson: '#A31621', 'crimson-light': '#C82333',
          muted: '#7A7A7A',
        },
        fontFamily: { sans: ['Inter','system-ui','sans-serif'], serif: ['"DM Serif Display"','Georgia','serif'] },
      },
    },
  }
</script>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin/>
<link href="https://fonts.googleapis.com/css2?family=Cinzel:wght@400;700&family=DM+Serif+Display:ital@0;1&family=Inter:wght@300;400;500;600;700&family=Montserrat:wght@400&display=swap" rel="stylesheet"/>
<style>
  html { background-color: #121212; }
  .form-input:focus { outline: none; border-color: #C9A84C; box-shadow: 0 0 0 2px rgba(201, 168, 76, 0.15); }
  .brief-body p { margin-bottom: 1.1em; }
  .brief-body p:last-child { margin-bottom: 0; }
</style>
</head>
<body class="bg-obsidian text-white font-sans antialiased selection:bg-gold selection:text-obsidian">
  <header class="fixed top-4 sm:top-5 inset-x-0 z-40 flex justify-center px-3 sm:px-5">
    <nav class="flex items-center justify-between gap-3 sm:gap-6 w-full max-w-xl rounded-full bg-obsidian/70 backdrop-blur-md border border-white/10 shadow-xl shadow-black/60 px-3 sm:px-4 py-2.5">
      <a href="${SITE}/" class="flex items-center flex-shrink-0">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="15 18 110 52" height="34" style="clip-path:path('M0 0 H200 V14 H0 Z M0 17 H200 V36 H0 Z')" aria-label="AFS Publishing">
          <g transform="translate(20,15)">
            <text font-family="'Cinzel',Georgia,serif" font-weight="400" fill="#EEECE9" font-size="38" letter-spacing="4" x="0" y="35">AFS</text>
            <text font-family="'Montserrat',system-ui,sans-serif" font-weight="400" fill="rgba(238,236,233,0.42)" font-size="9" letter-spacing="5" x="2" y="52">Publishing</text>
          </g>
        </svg>
      </a>
      <a href="${SITE}/dashboard/login.html" class="inline-flex items-center px-3 py-1.5 text-muted hover:text-white text-xs font-medium transition-colors duration-200">Writer Login</a>
    </nav>
  </header>
  <main class="pt-28 sm:pt-32 pb-24 px-4 sm:px-6 max-w-3xl mx-auto">
${body}
  </main>
  <footer class="border-t border-border py-10 px-6">
    <div class="max-w-3xl mx-auto flex flex-col sm:flex-row items-center justify-between gap-4">
      <p class="text-muted text-xs tracking-wide text-center">© 2026 Apex Fiction Studio. All rights reserved.</p>
      <a href="${SITE}/#apply" class="text-gold hover:text-gold-light transition-colors duration-150 text-xs font-medium">Full Application →</a>
    </div>
  </footer>
</body>
</html>`
}

function notFoundPage(): string {
  const head = `<title>This prompt isn't available — Apex Fiction Studio</title>
<meta name="description" content="This writing prompt may have been claimed or taken down."/>`
  const body = `
    <div class="text-center py-16">
      <p class="text-[11px] font-medium tracking-widest uppercase text-gold mb-4">Apex Fiction Studio</p>
      <h1 class="font-serif text-3xl sm:text-4xl text-white mb-4">This prompt isn't available.</h1>
      <p class="text-muted text-sm sm:text-base leading-relaxed max-w-md mx-auto mb-8">
        It may have been claimed, taken down, or the link is incorrect. Take a look at what else we're commissioning.
      </p>
      <a href="${SITE}/" class="inline-flex items-center gap-2 px-6 py-3 bg-gold hover:bg-gold-light text-obsidian text-sm font-semibold rounded-lg transition-colors duration-200">
        Visit Apex Fiction Studio
      </a>
    </div>`
  return pageShell(head, body)
}

function promptPage(p: Prompt, pageUrl: string): string {
  const title = escHtml(p.title)
  const ogImage = /^https:\/\//i.test(p.banner_url || '') ? (p.banner_url as string) : `${SITE}/assets/og-image.png`
  const ogDescription = escHtml(plainSnippet(p.brief, 200) || 'A commissioned writing prompt from Apex Fiction Studio.')

  const head = `<title>${title} — Apex Fiction Studio</title>
<meta name="description" content="${ogDescription}"/>
<link rel="canonical" href="${escHtml(pageUrl)}"/>
<meta property="og:type" content="website"/>
<meta property="og:url" content="${escHtml(pageUrl)}"/>
<meta property="og:title" content="${title} — Apex Fiction Studio"/>
<meta property="og:description" content="${ogDescription}"/>
<meta property="og:image" content="${escHtml(ogImage)}"/>
<meta property="og:site_name" content="Apex Fiction Studio"/>
<meta name="twitter:card" content="summary_large_image"/>
<meta name="twitter:title" content="${title} — Apex Fiction Studio"/>
<meta name="twitter:description" content="${ogDescription}"/>
<meta name="twitter:image" content="${escHtml(ogImage)}"/>`

  const banner = p.banner_url
    ? `<img src="${escHtml(p.banner_url)}" alt="" class="absolute inset-0 w-full h-full object-cover"/>`
    : `<div class="absolute inset-0" style="background:radial-gradient(ellipse at 30% 20%,rgba(163,22,33,0.14),transparent 55%),linear-gradient(135deg,#1C1C1C,#242424)"></div>`

  const tags = Array.isArray(p.tags) ? p.tags : []
  const tagsHtml = tags.length
    ? `<span class="flex flex-wrap gap-1.5">${tags.map(t => `<span class="inline-block text-[10px] font-medium text-white/70 bg-white/5 border border-border rounded-full px-2.5 py-1">${escHtml(t)}</span>`).join('')}</span>`
    : ''

  const sampleUrl = (p.sample_chapter_url || '').trim()
  const sampleLink = /^https?:\/\//i.test(sampleUrl)
    ? `<a href="${escHtml(sampleUrl)}" target="_blank" rel="noopener noreferrer" class="inline-flex items-center gap-2 text-sm text-gold hover:text-gold-light transition-colors mb-8">
         Read a Sample Chapter
         <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M7 17L17 7"/><path d="M7 7h10v10"/></svg>
       </a>`
    : ''

  const body = `
    <article>
      <div class="relative aspect-[2/1] rounded-2xl overflow-hidden border border-border bg-charcoal mb-6">
        ${banner}
        <div class="absolute inset-0" style="background:linear-gradient(to top,rgba(13,11,9,0.75),transparent 55%)"></div>
      </div>

      <p class="text-[11px] font-medium tracking-widest uppercase text-gold mb-3">A Writing Prompt from Apex Fiction Studio</p>
      <div class="flex flex-wrap items-center gap-2 mb-3">
        ${p.genre ? `<span class="text-[10px] font-semibold tracking-widest uppercase text-gold/90 bg-gold/10 border border-gold/25 rounded-full px-2.5 py-1">${escHtml(p.genre)}</span>` : ''}
        ${tagsHtml}
      </div>
      <h1 class="font-serif text-3xl sm:text-4xl text-white leading-tight mb-6">${title}</h1>

      <div class="brief-body text-white/80 text-[15px] sm:text-base leading-[1.9] mb-8">${briefToHtml(p.brief)}</div>

      ${sampleLink}

      <div class="rounded-2xl border border-gold/25 bg-surface p-6 sm:p-8 text-center">
        <h2 class="font-serif text-xl sm:text-2xl text-white mb-2">Want to write this one?</h2>
        <p class="text-muted text-sm mb-5">Tell us a little about yourself — takes ten seconds.</p>
        <button onclick="openJoinModal()" class="inline-flex items-center gap-2 px-6 py-3 bg-gold hover:bg-gold-light text-obsidian text-sm font-semibold rounded-lg transition-colors duration-200">
          I Want to Write This
        </button>
      </div>
    </article>

    <div id="join-modal" class="hidden fixed inset-0 z-50 flex items-end sm:items-center justify-center p-0 sm:p-6" style="background:rgba(0,0,0,0.75);backdrop-filter:blur(4px)">
      <div class="w-full sm:max-w-md bg-charcoal sm:rounded-2xl border border-border overflow-hidden">
        <div id="join-form-wrap" class="p-6 sm:p-8">
          <div class="flex items-start justify-between gap-3 mb-1">
            <h3 class="font-serif text-xl text-white">Interested in Writing This?</h3>
            <button onclick="closeJoinModal()" class="flex-shrink-0 w-8 h-8 rounded-full border border-border hover:border-white/25 flex items-center justify-center text-muted hover:text-white transition-colors">
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M18 6L6 18M6 6l12 12"/></svg>
            </button>
          </div>
          <p class="text-muted text-sm mb-6">Just your name, email, and a line about your writing experience. We'll be in touch.</p>
          <form id="join-form" class="space-y-4">
            <div>
              <label class="block text-xs font-medium text-white/70 tracking-wide mb-2" for="lead-name">Full Name</label>
              <input id="lead-name" name="name" type="text" autocomplete="name" placeholder="Jane Moriarty" required
                     class="form-input w-full bg-obsidian border border-border text-white placeholder-muted text-sm rounded-lg px-4 py-2.5 transition-all duration-200"/>
            </div>
            <div>
              <label class="block text-xs font-medium text-white/70 tracking-wide mb-2" for="lead-email">Email Address</label>
              <input id="lead-email" name="email" type="email" autocomplete="email" placeholder="jane@email.com" required
                     class="form-input w-full bg-obsidian border border-border text-white placeholder-muted text-sm rounded-lg px-4 py-2.5 transition-all duration-200"/>
            </div>
            <div>
              <label class="block text-xs font-medium text-white/70 tracking-wide mb-2" for="lead-experience">Writing Experience</label>
              <input id="lead-experience" name="experience" type="text" placeholder="e.g. New to writing, or 2 years on Wattpad"
                     class="form-input w-full bg-obsidian border border-border text-white placeholder-muted text-sm rounded-lg px-4 py-2.5 transition-all duration-200"/>
            </div>
            <div style="position:absolute;left:-9999px;top:-9999px;width:1px;height:1px;overflow:hidden;" aria-hidden="true" tabindex="-1">
              <label for="lead-website">Website</label>
              <input type="text" id="lead-website" name="website" autocomplete="off" tabindex="-1" value=""/>
            </div>
            <div id="join-error" class="hidden text-xs text-red-400 bg-red-400/10 border border-red-400/20 rounded-lg px-4 py-2.5"></div>
            <button id="join-submit-btn" type="submit"
                    class="w-full flex items-center justify-center gap-2 px-6 py-3 bg-gold hover:bg-gold-light text-obsidian text-sm font-semibold rounded-lg transition-colors duration-200 disabled:opacity-60 disabled:cursor-not-allowed">
              <span id="join-submit-label">Join &amp; Send</span>
              <svg id="join-submit-spinner" class="hidden animate-spin w-4 h-4" viewBox="0 0 24 24" fill="none"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"/></svg>
            </button>
          </form>
        </div>
        <div id="join-success" class="hidden p-6 sm:p-8 text-center">
          <div class="w-14 h-14 rounded-full bg-gold/10 border border-gold/30 flex items-center justify-center mx-auto mb-5">
            <svg class="w-6 h-6 text-gold" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg>
          </div>
          <h3 class="font-serif text-xl text-white mb-2">Thanks — we'll be in touch.</h3>
          <p class="text-muted text-sm leading-relaxed mb-6">We read every application personally.</p>
          <button onclick="closeJoinModal()" class="text-muted hover:text-white text-xs transition-colors">Continue Reading</button>
        </div>
      </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
    <script>
      (function () {
        var SUPABASE_URL = ${JSON.stringify(Deno.env.get('SUPABASE_URL') || '')};
        var SUPABASE_ANON_KEY = ${JSON.stringify(Deno.env.get('SUPABASE_ANON_KEY') || '')};
        var PROMPT_ID = ${JSON.stringify(p.id)};
        var db = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

        function $(id) { return document.getElementById(id); }

        var joinShown = false;
        var joinOpenedAt = 0;

        window.openJoinModal = function () {
          joinShown = true;
          joinOpenedAt = Date.now();
          $('join-form-wrap').classList.remove('hidden');
          $('join-success').classList.add('hidden');
          $('join-modal').classList.remove('hidden');
        };
        window.closeJoinModal = function () {
          $('join-modal').classList.add('hidden');
        };
        $('join-modal').addEventListener('click', function (e) { if (e.target === e.currentTarget) closeJoinModal(); });

        setTimeout(function () { if (!joinShown) openJoinModal(); }, 6000);

        var form = $('join-form');
        var btn = $('join-submit-btn');
        var btnLbl = $('join-submit-label');
        var spinner = $('join-submit-spinner');
        var errBox = $('join-error');

        form.addEventListener('submit', function (e) {
          e.preventDefault();
          errBox.classList.add('hidden');

          var cooldownKey = 'afs_app_sent_' + PROMPT_ID;
          var lastSent = localStorage.getItem(cooldownKey);
          if (lastSent && (Date.now() - Number(lastSent)) < 3600000) {
            errBox.textContent = "You've already applied for this prompt. We'll be in touch.";
            errBox.classList.remove('hidden');
            return;
          }

          var honeypot = form.website ? form.website.value : '';
          if (honeypot !== '') {
            $('join-form-wrap').classList.add('hidden');
            $('join-success').classList.remove('hidden');
            return;
          }

          if ((Date.now() - joinOpenedAt) < 1200) {
            errBox.textContent = 'Please take a moment to complete the form.';
            errBox.classList.remove('hidden');
            return;
          }

          var name = form.name.value.trim();
          var email = form.email.value.trim().toLowerCase();
          var experience = form.experience.value.trim() || null;

          if (name.length < 1 || name.length > 120 || email.length > 200 || (experience && experience.length > 2000)) {
            errBox.textContent = 'Please check your entries and try again.';
            errBox.classList.remove('hidden');
            return;
          }

          btn.disabled = true;
          btnLbl.textContent = 'Sending…';
          spinner.classList.remove('hidden');

          db.from('applications').insert({
            prompt_id: PROMPT_ID, source: 'prompt_link', name: name, email: email, experience: experience,
          }).then(function (result) {
            btn.disabled = false;
            btnLbl.textContent = 'Join & Send';
            spinner.classList.add('hidden');

            if (result.error) {
              console.error('AFS application error:', result.error);
              var msg = 'Something went wrong. Please try again.';
              if (result.error.code === '23505') {
                msg = 'An application with this email already exists. Reach out to us directly if you need to update it.';
              } else if (result.error.code === '42501' || (result.error.message && result.error.message.toLowerCase().indexOf('security') !== -1)) {
                msg = 'Submissions are temporarily unavailable. Please try again in a few minutes or email us directly.';
              } else if (result.error.message) {
                msg = 'Error: ' + result.error.message;
              }
              errBox.textContent = msg;
              errBox.classList.remove('hidden');
              return;
            }

            localStorage.setItem(cooldownKey, String(Date.now()));
            $('join-form-wrap').classList.add('hidden');
            $('join-success').classList.remove('hidden');
          }, function (networkErr) {
            console.error('AFS application network error:', networkErr);
            btn.disabled = false;
            btnLbl.textContent = 'Join & Send';
            spinner.classList.add('hidden');
            errBox.textContent = 'Network error — please check your connection and try again.';
            errBox.classList.remove('hidden');
          });
        });
      })();
    </script>`

  return pageShell(head, body)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const url = new URL(req.url)
  const id = (url.searchParams.get('id') || '').trim()

  const htmlHeaders = { ...corsHeaders, 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=300' }

  if (!UUID_RE.test(id)) {
    return new Response(notFoundPage(), { headers: htmlHeaders, status: 404 })
  }

  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
  )

  const { data, error } = await db.from('writing_prompts')
    .select('id, title, brief, genre, banner_url, tags, sample_chapter_url')
    .eq('id', id)
    .eq('is_active', true)
    .eq('review_status', 'approved')
    .maybeSingle()

  if (error || !data) {
    return new Response(notFoundPage(), { headers: htmlHeaders, status: 404 })
  }

  return new Response(promptPage(data as Prompt, req.url), { headers: htmlHeaders, status: 200 })
})
