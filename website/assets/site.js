const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
const revealItems = document.querySelectorAll(".reveal");
const sections = [...document.querySelectorAll(".section-anchor[id]")];
const navLinks = [...document.querySelectorAll(".nav-links a")];
const parallaxItems = [...document.querySelectorAll(".media-parallax img")];
const currentPage = (window.location.pathname.split("/").pop() || "index.html").toLowerCase();

function reveal() {
  if (motionQuery.matches) {
    revealItems.forEach((item) => item.classList.add("is-visible"));
    return;
  }

  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.14 });

  revealItems.forEach((item) => observer.observe(item));
  window.setTimeout(() => revealItems.forEach((item) => item.classList.add("is-visible")), 900);
}

function highlightNav() {
  navLinks.forEach((link) => {
    const href = link.getAttribute("href") || "";
    const targetPage = (href.split("#")[0].split("/").pop() || "index.html").toLowerCase();
    const isCurrent = targetPage === currentPage || (currentPage === "" && targetPage === "index.html");
    link.classList.toggle("is-active", isCurrent);
    link.classList.toggle("current", isCurrent);
  });
}

function parallax() {
  if (motionQuery.matches) return;
  const viewport = window.innerHeight || 1;
  parallaxItems.forEach((img) => {
    const rect = img.getBoundingClientRect();
    const progress = (rect.top + rect.height / 2 - viewport / 2) / viewport;
    const shift = Math.max(-10, Math.min(10, progress * -12));
    img.style.transform = `translateY(${shift}px)`;
  });
}

function onScroll() {
  highlightNav();
  parallax();
}

reveal();
highlightNav();
parallax();
window.addEventListener("scroll", onScroll, { passive: true });
window.addEventListener("resize", onScroll);
