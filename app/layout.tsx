import { Geist, Geist_Mono, Noto_Sans } from "next/font/google"

import { ThemeProvider } from "@wrksz/themes/next"

import "./globals.css"
import { ThemeHotkey } from "@/components/theme-hotkey"
import { cn } from "@/lib/utils"
import { TooltipProvider } from "@/components/ui/tooltip"
import { Toaster } from "@/components/ui/sonner"

const notoSans = Noto_Sans({ subsets: ['latin'], variable: '--font-sans' })

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
          <TooltipProvider>
            <ThemeHotkey />
            <Toaster />
            {children}
          </TooltipProvider>
        </ThemeProvider>
      </body>
    </html>
  )
}
