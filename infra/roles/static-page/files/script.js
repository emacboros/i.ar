// ═══════════════════════════════════════════════════════════
// i.ar — Professional landing page
// Minimal, clean interactions
// ═══════════════════════════════════════════════════════════

document.addEventListener('DOMContentLoaded', () => {

    // ── Mobile navigation toggle ────────────────────────────
    const navToggle = document.getElementById('nav-toggle');
    const navLinks = document.querySelector('.nav-links');

    if (navToggle && navLinks) {
        navToggle.addEventListener('click', () => {
            navLinks.classList.toggle('open');
        });

        // Close mobile nav when clicking a link
        navLinks.querySelectorAll('a').forEach(link => {
            link.addEventListener('click', () => {
                navLinks.classList.remove('open');
            });
        });
    }

    // ── Scroll reveal animations ────────────────────────────
    const revealElements = document.querySelectorAll('section');
    revealElements.forEach(el => el.classList.add('reveal'));

    const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('visible');
            }
        });
    }, {
        threshold: 0.1,
        rootMargin: '0px 0px -50px 0px'
    });

    revealElements.forEach(el => observer.observe(el));

    // ── Navbar shadow on scroll ─────────────────────────────
    const nav = document.getElementById('nav');
    let lastScroll = 0;

    window.addEventListener('scroll', () => {
        const currentScroll = window.pageYOffset;

        if (currentScroll > 20) {
            nav.style.padding = '10px 32px';
            nav.style.boxShadow = '0 4px 20px rgba(0, 0, 0, 0.3)';
        } else {
            nav.style.padding = '16px 32px';
            nav.style.boxShadow = 'none';
        }

        lastScroll = currentScroll;
    }, { passive: true });

    // ── Contact form handler ────────────────────────────────
    // Note: This is a front-end only handler. To make it functional,
    // point it to your backend endpoint or email service.
});

// ── Form submission ─────────────────────────────────────────
function handleSubmit(event) {
    event.preventDefault();

    const form = event.target;
    const note = document.getElementById('form-note');
    const formData = new FormData(form);
    const data = Object.fromEntries(formData);

    // Build a mailto link as a fallback (no backend required)
    const subject = encodeURIComponent(`i.ar inquiry: ${data.interest || 'general'}`);
    const body = encodeURIComponent(
        `Name: ${data.name}\n` +
        `Email: ${data.email}\n` +
        `Organization: ${data.org || 'N/A'}\n` +
        `Interest: ${data.interest || 'N/A'}\n\n` +
        `Message:\n${data.message || 'N/A'}`
    );

    // Show confirmation
    note.textContent = 'Opening your email client...';
    note.style.color = 'var(--accent)';

    // Open mailto
    window.location.href = `mailto:ignacio@randazzo.ar?subject=${subject}&body=${body}`;

    // Reset after delay
    setTimeout(() => {
        note.textContent = '';
        form.reset();
    }, 3000);

    return false;
}