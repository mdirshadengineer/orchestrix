import { Navbar } from "./_components/navbar";

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
   <div className="fixed inset-0">
    <Navbar />
   {children}
   </div>
  );
}