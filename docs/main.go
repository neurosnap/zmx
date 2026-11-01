package main

import (
	"log/slog"
	"math/rand"
	"strconv"

	"github.com/picosh/pdocs"
)

func main() {
	pager := pdocs.Pager("./posts")
	sitemap := &pdocs.Sitemap{
		Children: []*pdocs.Sitemap{
			{
				Text: "Home",
				Href: "/",
				Page: pager("home.md"),
			},
			{
				Text: "Sitemap",
				Href: "/sitemap",
				Page: pager("sitemap.md"),
			},
			{
				Text: "Getting started",
				Children: []*pdocs.Sitemap{
					{
						Text: "Install & Usage",
						Href: "/getting-started",
						Page: pager("getting-started.md"),
					},
					{
						Text: "Shell integration",
						Href: "/shell-integration",
						Page: pager("shell-integration.md"),
					},
					{
						Text: "SSH workflow",
						Href: "/ssh",
						Page: pager("ssh.md"),
					},
				},
			},
			{
				Text: "Guides & Reference",
				Children: []*pdocs.Sitemap{
					{
						Text: "Zig package",
						Href: "/zig-package",
						Page: pager("zig-package.md"),
					},
					{
						Text: "Configuration & Debugging",
						Href: "/configuration",
						Page: pager("configuration.md"),
					},
					{
						Text: "Architecture & Philosophy",
						Href: "/architecture",
						Page: pager("architecture.md"),
					},
					{
						Text: "Community tools",
						Href: "/community",
						Page: pager("community.md"),
					},
				},
			},
		},
	}

	logger := slog.Default()
	config := &pdocs.DocConfig{
		Logger:   logger,
		Sitemap:  sitemap,
		Out:      "./public",
		Tmpl:     "./tmpl",
		PageTmpl: "post.page.tmpl",
		CacheId:  strconv.Itoa(rand.Intn(10000)),
	}

	err := config.GenSite()
	if err != nil {
		panic(err)
	}
}
