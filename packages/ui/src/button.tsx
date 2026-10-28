import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { Slot } from "radix-ui";

import { cn } from "./utils";

const buttonVariants = cva(
  "group/button inline-flex shrink-0 cursor-pointer items-center justify-center rounded-[9px] border border-transparent bg-clip-padding text-sm font-semibold whitespace-nowrap transition-[background-color,color,border-color,box-shadow,transform] duration-150 outline-none select-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/25 active:not-aria-[haspopup]:translate-y-px disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-3 aria-invalid:ring-destructive/20 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        default:
          "border-primary bg-primary text-primary-foreground shadow-[0_4px_10px_rgba(17,41,33,.16)] hover:border-primary/90 hover:bg-primary/90 hover:shadow-[0_6px_14px_rgba(17,41,33,.2)]",
        outline:
          "border-input bg-background text-foreground shadow-[0_1px_2px_rgba(17,41,33,.04)] hover:border-primary/35 hover:bg-secondary aria-expanded:border-primary/35 aria-expanded:bg-secondary",
        secondary:
          "border-primary/15 bg-secondary text-secondary-foreground hover:border-primary/25 hover:bg-accent aria-expanded:bg-accent aria-expanded:text-accent-foreground",
        ghost:
          "text-foreground hover:bg-secondary hover:text-foreground aria-expanded:bg-secondary aria-expanded:text-foreground",
        success:
          "border-primary/25 bg-accent text-accent-foreground hover:border-primary/35 hover:bg-accent/75",
        destructive:
          "border-destructive bg-destructive text-white shadow-[0_4px_10px_rgba(190,35,55,.12)] hover:bg-destructive/90 focus-visible:border-destructive focus-visible:ring-destructive/20",
        "destructive-outline":
          "border-destructive/45 bg-background text-destructive hover:border-destructive/65 hover:bg-destructive/8 focus-visible:border-destructive focus-visible:ring-destructive/20",
        "destructive-ghost":
          "text-destructive hover:bg-destructive/8 hover:text-destructive focus-visible:border-destructive/40 focus-visible:ring-destructive/20",
        link: "text-primary underline-offset-4 hover:underline",
      },
      size: {
        default:
          "h-11 gap-2 px-4 has-data-[icon=inline-end]:pr-3.5 has-data-[icon=inline-start]:pl-3.5",
        xs: "h-7 gap-1.5 rounded-[7px] px-2.5 text-xs in-data-[slot=button-group]:rounded-lg has-data-[icon=inline-end]:pr-2 has-data-[icon=inline-start]:pl-2 [&_svg:not([class*='size-'])]:size-3.5",
        sm: "h-9 gap-1.5 rounded-lg px-3 text-xs in-data-[slot=button-group]:rounded-lg has-data-[icon=inline-end]:pr-2.5 has-data-[icon=inline-start]:pl-2.5 [&_svg:not([class*='size-'])]:size-3.5",
        lg: "h-12 gap-2 px-5 has-data-[icon=inline-end]:pr-4.5 has-data-[icon=inline-start]:pl-4.5",
        icon: "size-11",
        "icon-xs":
          "size-7 rounded-[7px] in-data-[slot=button-group]:rounded-lg [&_svg:not([class*='size-'])]:size-3.5",
        "icon-sm": "size-9 rounded-lg in-data-[slot=button-group]:rounded-lg",
        "icon-lg": "size-12",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  },
);

function Button({
  className,
  variant = "default",
  size = "default",
  asChild = false,
  ...props
}: React.ComponentProps<"button"> &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean;
  }) {
  const Comp = asChild ? Slot.Root : "button";

  return (
    <Comp
      data-slot="button"
      data-variant={variant}
      data-size={size}
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  );
}

export { Button, buttonVariants };
