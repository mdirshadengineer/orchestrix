import { Geist, Geist_Mono, Noto_Sans } from "next/font/google"

import { ThemeProvider } from "@wrksz/themes/next"

import "./globals.css"
import { ThemeHotkey } from "@/components/theme-hotkey"
import { cn } from "@/lib/utils"

const notoSans = Noto_Sans({subsets:['latin'],variable:'--font-sans'})

const fontMono = Geist_Mono({
  subsets: ["latin"],
  variable: "--font-mono",
})

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html
      lang="en"
      suppressHydrationWarning
      className={cn("antialiased", fontMono.variable, "font-sans", notoSans.variable)}
    >
      <body>
        <ThemeProvider
          attribute="class"
          defaultTheme="system"
          storage="cookie"
          storageKey="orchestrix-theme"
          enableSystem
          disableTransitionOnChange
        >
          <ThemeHotkey />
          {children}
        </ThemeProvider>
      </body>
    </html>
  )
}
