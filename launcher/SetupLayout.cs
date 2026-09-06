// Copyright (c) 2026 John Lightfoot
// SPDX-License-Identifier: MIT
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace KiloLink.Setup
{
    internal sealed partial class SetupForm
    {
        private sealed class LayoutItem
        {
            internal Control Control;
            internal Rectangle OriginalBounds;
        }

        private sealed class LayoutRow
        {
            internal int OriginalTop;
            internal readonly List<LayoutItem> Items = new List<LayoutItem>();
        }

        private sealed class LayoutFont
        {
            internal string Family;
            internal float Pixels;
            internal FontStyle Style;
        }

        private readonly Dictionary<Panel, List<LayoutRow>> pageRows = new Dictionary<Panel, List<LayoutRow>>();
        private readonly Dictionary<Control, LayoutFont> layoutFonts = new Dictionary<Control, LayoutFont>();
        private readonly List<Font> scaledFonts = new List<Font>();
        private readonly Dictionary<string, Font> fontCache = new Dictionary<string, Font>();
        private Panel adaptiveHeader;
        private PictureBox headerArtwork;
        private Label headerTitle;
        private Label headerSubtitle;
        private float displayScale = 1F;
        private bool fittingPage;
        private bool fitQueued;

        private int Px(float value) { return Math.Max(1, (int)Math.Ceiling(value * displayScale)); }

        private void InitializeAdaptiveLayout(Panel header, PictureBox artwork, Label title, Label subtitle)
        {
            adaptiveHeader = header;
            headerArtwork = artwork;
            headerTitle = title;
            headerSubtitle = subtitle;
            foreach (Panel page in new Panel[] { rolePanel, welcomePanel, networkPanel, settingsPanel, reviewPanel, progressPanel })
            {
                List<LayoutItem> items = new List<LayoutItem>();
                foreach (Control control in page.Controls)
                {
                    items.Add(new LayoutItem { Control = control, OriginalBounds = control.Bounds });
                    Label label = control as Label;
                    if (label != null) { label.AutoSize = false; label.AutoEllipsis = false; label.UseMnemonic = false; }
                    control.Anchor = AnchorStyles.Top | AnchorStyles.Left;
                    control.TextChanged += delegate { QueueFit(); };
                    control.VisibleChanged += delegate { QueueFit(); };
                }
                items.Sort(delegate(LayoutItem a, LayoutItem b) {
                    int top = a.OriginalBounds.Top.CompareTo(b.OriginalBounds.Top);
                    return top == 0 ? a.OriginalBounds.Left.CompareTo(b.OriginalBounds.Left) : top;
                });
                List<LayoutRow> rows = new List<LayoutRow>();
                foreach (LayoutItem item in items)
                {
                    LayoutRow row = rows.Count == 0 ? null : rows[rows.Count - 1];
                    if (row == null || item.OriginalBounds.Top - row.OriginalTop > 8)
                    {
                        row = new LayoutRow { OriginalTop = item.OriginalBounds.Top };
                        rows.Add(row);
                    }
                    row.Items.Add(item);
                }
                foreach (LayoutRow row in rows) { row.Items.Sort(delegate(LayoutItem a, LayoutItem b) { return a.OriginalBounds.Left.CompareTo(b.OriginalBounds.Left); }); }
                pageRows.Add(page, rows);
            }
            Queue<Control> controls = new Queue<Control>();
            controls.Enqueue(this);
            while (controls.Count > 0)
            {
                Control control = controls.Dequeue();
                Font font = control.Font;
                layoutFonts.Add(control, new LayoutFont { Family = font.FontFamily.Name, Pixels = font.SizeInPoints * 96F / 72F, Style = font.Style });
                foreach (Control child in control.Controls) { controls.Enqueue(child); }
            }
            Disposed += delegate { foreach (Font font in scaledFonts) { font.Dispose(); } };
        }

        // Pixel fonts avoid mixing WinForms autoscaling with a separately scaled outer window.
        // The same path runs on initial display, WM_DPICHANGED, and layout regression checks.
        private void ApplyDisplayScale(float scale)
        {
            displayScale = Math.Max(1F, Math.Min(4F, scale));
            fittingPage = true;
            SuspendLayout();
            try
            {
                foreach (KeyValuePair<Control, LayoutFont> item in layoutFonts)
                {
                    LayoutFont source = item.Value;
                    string key = source.Family + "|" + source.Style + "|" + (source.Pixels * displayScale).ToString(System.Globalization.CultureInfo.InvariantCulture);
                    Font font;
                    if (!fontCache.TryGetValue(key, out font))
                    {
                        font = new Font(source.Family, source.Pixels * displayScale, source.Style, GraphicsUnit.Pixel);
                        fontCache.Add(key, font);
                        scaledFonts.Add(font);
                    }
                    item.Key.Font = font;
                }
            }
            finally
            {
                ResumeLayout(false);
                fittingPage = false;
            }
        }

        private void QueueFit()
        {
            if (fittingPage || fitQueued || !Visible || !IsHandleCreated || IsDisposed) { return; }
            fitQueued = true;
            BeginInvoke((MethodInvoker)delegate {
                fitQueued = false;
                if (!IsDisposed) { FitCurrentPage(false); }
            });
        }

        private Panel CurrentPage()
        {
            switch (currentView)
            {
                case LauncherView.Role: return rolePanel;
                case LauncherView.Network: return networkPanel;
                case LauncherView.Settings: return settingsPanel;
                case LauncherView.Review: return reviewPanel;
                case LauncherView.Progress: return progressPanel;
                default: return welcomePanel;
            }
        }

        private int MeasureHeight(Control control, int width)
        {
            if (control is InstallerProgressBar) { return Px(30); }
            TextBox text = control as TextBox;
            if (text != null && !text.Multiline) { return text.PreferredHeight; }
            ComboBox combo = control as ComboBox;
            if (combo != null) { return combo.PreferredHeight; }
            if (control is NumericUpDown) { return control.PreferredSize.Height; }
            int allowance = control is CheckBox || control is RadioButton ? Px(24) : text != null ? Px(12) : 0;
            Size measured = TextRenderer.MeasureText(control.Text.Length == 0 ? " " : control.Text, control.Font,
                new Size(Math.Max(Px(24), width - allowance), Int32.MaxValue),
                TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl);
            int height = measured.Height + (text != null ? Px(10) : Px(2));
            if (control is Button) { height = Math.Max(Px(34), height + Px(12)); }
            if (control is RadioButton || control is CheckBox) { height = Math.Max(Px(24), height); }
            if (control == progressStatusLabel) { height = Math.Max(Px(42), height); }
            return height;
        }

        private int LayoutPage(Panel page, int pageWidth)
        {
            int padding = Px(22);
            int available = Math.Max(Px(60), pageWidth - padding * 2);
            int y = Px(18);
            bool previousRadio = false;
            foreach (LayoutRow row in pageRows[page])
            {
                // Empty status labels must not retain old bounds and cover a
                // newly reflowed field underneath them.
                foreach (LayoutItem item in row.Items)
                {
                    if (item.Control is Label && String.IsNullOrEmpty(item.Control.Text)) { item.Control.SetBounds(0, 0, 0, 0); }
                }
                List<LayoutItem> visible = row.Items.FindAll(delegate(LayoutItem item) {
                    return item.Control.Visible && (!(item.Control is Label) || !String.IsNullOrEmpty(item.Control.Text));
                });
                if (visible.Count == 0) { continue; }
                bool buttons = visible.TrueForAll(delegate(LayoutItem item) { return item.Control is Button; });
                if (buttons)
                {
                    y += Px(8);
                    int x = padding;
                    int rowHeight = 0;
                    int total = 0;
                    List<int> widths = new List<int>();
                    foreach (LayoutItem item in visible)
                    {
                        int width = Math.Min(available, Math.Max(Px(96), TextRenderer.MeasureText(item.Control.Text, item.Control.Font).Width + Px(24)));
                        widths.Add(width);
                        total += width + Px(8);
                    }
                    for (int index = 0; index < visible.Count; index++)
                    {
                        Control control = visible[index].Control;
                        int width = widths[index];
                        if (index == 1 && total - Px(8) <= available) { x = padding + available - (total - widths[0] - Px(16)); }
                        if (x > padding && x + width > padding + available)
                        {
                            y += rowHeight + Px(8); x = padding; rowHeight = 0;
                        }
                        int height = MeasureHeight(control, width);
                        control.SetBounds(x, y, width, height);
                        rowHeight = Math.Max(rowHeight, height);
                        x += width + Px(8);
                    }
                    y += rowHeight + Px(8);
                }
                else
                {
                    int height = 0;
                    for (int index = 0; index < visible.Count; index++)
                    {
                        LayoutItem item = visible[index];
                        Control control = item.Control;
                        int indent = visible.Count == 1 ? Math.Max(0, Math.Min(24, item.OriginalBounds.Left - 34)) : 0;
                        int x = padding + Px(indent) - (indent == 0 ? 1 : 0);
                        int width = available - (x - padding);
                        if (visible.Count > 1)
                        {
                            float originalWidth = page == networkPanel ? 696F : 716F;
                            float left = Math.Max(0, item.OriginalBounds.Left - 34);
                            float right = index + 1 < visible.Count ? visible[index + 1].OriginalBounds.Left - 34 : originalWidth;
                            x = padding + (int)Math.Round(available * left / originalWidth);
                            width = Math.Max(Px(30), (int)Math.Round(available * (right - left) / originalWidth) - (index + 1 < visible.Count ? Px(10) : 0));
                        }
                        if (control is LinkLabel) { width = Math.Min(width, TextRenderer.MeasureText(control.Text, control.Font).Width + Px(8)); }
                        int controlHeight = MeasureHeight(control, width);
                        control.SetBounds(x, y, width, controlHeight);
                        TextBox box = control as TextBox;
                        if (box != null && box.Multiline) { box.ScrollBars = ScrollBars.None; }
                        height = Math.Max(height, controlHeight);
                    }
                    bool radio = visible[0].Control is RadioButton;
                    y += height + Px(radio ? 2 : previousRadio ? 12 : 8);
                    previousRadio = radio;
                }
            }
            return y + Px(12);
        }

        private int LayoutHeader(int width)
        {
            int padding = Px(16);
            int artworkSize = Px(60);
            headerArtwork.SetBounds(padding, padding, artworkSize, artworkSize);
            int left = padding + artworkSize + Px(14);
            int textWidth = Math.Max(Px(80), width - left - padding);
            singleFileBadge.Visible = false;
            headerTitle.AutoSize = false;
            headerSubtitle.AutoSize = false;
            int titleHeight = MeasureHeight(headerTitle, textWidth);
            int subtitleHeight = MeasureHeight(headerSubtitle, textWidth);
            int height = Math.Max(artworkSize, titleHeight + Px(4) + subtitleHeight) + padding * 2;
            headerTitle.SetBounds(left, (height - titleHeight - Px(4) - subtitleHeight) / 2, textWidth, titleHeight);
            headerSubtitle.SetBounds(left, headerTitle.Bottom + Px(4), textWidth, subtitleHeight);
            foreach (Control control in adaptiveHeader.Controls) { if (control is Panel) { control.Height = Px(3); } }
            adaptiveHeader.Height = height + Px(3);
            return adaptiveHeader.Height;
        }

        private void FitCurrentPage(bool center)
        {
            FitPageToArea(Screen.FromControl(this).WorkingArea, center);
        }

        private void FitPageToArea(Rectangle work, bool center)
        {
            if (fittingPage || !Visible || pageRows.Count == 0) { return; }
            fittingPage = true;
            Panel page = CurrentPage();
            int borderWidth = Width - ClientSize.Width;
            int borderHeight = Height - ClientSize.Height;
            int maximumWidth = Math.Max(1, work.Width - borderWidth - Px(24));
            int maximumHeight = Math.Max(1, work.Height - borderHeight - Px(24));
            int width = Math.Min(Px(680), maximumWidth);
            SuspendLayout();
            try
            {
                page.AutoScrollPosition = Point.Empty;
                page.AutoScrollMinSize = Size.Empty;
                int headerHeight = LayoutHeader(width);
                int contentHeight = LayoutPage(page, width);
                bool scrolling = contentHeight + headerHeight > maximumHeight;
                if (scrolling) { contentHeight = LayoutPage(page, width - SystemInformation.VerticalScrollBarWidth); }
                ClientSize = new Size(width, Math.Min(maximumHeight, contentHeight + headerHeight));
                page.AutoScrollMinSize = new Size(0, contentHeight);
                if (center)
                {
                    Location = new Point(work.Left + Math.Max(0, (work.Width - Width) / 2), work.Top + Math.Max(0, (work.Height - Height) / 2));
                }
                else
                {
                    Location = new Point(Math.Max(work.Left, Math.Min(Left, work.Right - Width)), Math.Max(work.Top, Math.Min(Top, work.Bottom - Height)));
                }
            }
            finally { ResumeLayout(true); fittingPage = false; }
        }
    }
}
